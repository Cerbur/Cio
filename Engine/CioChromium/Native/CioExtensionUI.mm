#include "chrome/browser/ui/cio/CioExtensionUI.h"
#include "chrome/browser/ui/cio/CioNativeRuntime.h"
#include "chrome/browser/ui/cio/CioWindowHooks.h"
#import "chrome/browser/ui/cio/CioExtensionInstallRequest.h"

#import <AppKit/AppKit.h>
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/scoped_observation.h"
#include "base/timer/timer.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/profiles/profile.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/web_contents_observer.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/install_prompt_data.h"
#include "extensions/browser/install/crx_install_error.h"
#include "extensions/common/extension.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"

namespace { class NativeInstallPrompt; }

@interface CioExtensionInstallRequest ()
@property(nonatomic, readwrite) BOOL canAccept;
- (instancetype)initWithPrompt:(std::shared_ptr<NativeInstallPrompt>)prompt
                         parent:(NSWindow*)parent;
@end

namespace {
// Operational input protection, matching Chromium's ordinary install prompt.
// This is not a visual animation clock.
constexpr base::TimeDelta kInstallInputProtectionDelay = base::Milliseconds(500);

class NativeInstallPrompt final
    : public content::WebContentsObserver,
      public extensions::ExtensionRegistryObserver,
      public std::enable_shared_from_this<NativeInstallPrompt> {
 public:
  NativeInstallPrompt(std::unique_ptr<ExtensionInstallPromptShowParams> params,
      extensions::ExtensionInstallPromptClient::DoneCallback callback,
      std::unique_ptr<extensions::InstallPromptData> prompt)
      : content::WebContentsObserver(params->GetParentWebContents()),
        params_(std::move(params)), callback_(std::move(callback)),
        prompt_(std::move(prompt)) {
    registry_.Observe(extensions::ExtensionRegistry::Get(params_->profile()));
  }
  ~NativeInstallPrompt() override { Finish(false); }

  const extensions::InstallPromptData& data() const { return *prompt_; }
  void SetRequest(CioExtensionInstallRequest* request) { request_ = request; }

  void Presented(NSWindow* window) {
    if (!callback_ || presented_) return;
    window_ = window;
    presented_ = true;
    // ExtensionInstallPrompt already notified OnDialogOpened before dispatch.
    ready_timer_.Start(FROM_HERE, kInstallInputProtectionDelay,
        base::BindOnce([](std::weak_ptr<NativeInstallPrompt> weak) {
          if (auto state = weak.lock(); state && state->callback_) {
            state->ready_ = true;
            state->request_.canAccept = YES;
          }
        }, weak_from_this()));
  }

  void Finish(bool accepted) {
    if (!callback_) return;
    if (accepted && (!ready_ || !cio::CanInteractWithExtensionPrompt(window_))) return;
    accepted = accepted && !params_->WasParentDestroyed();
    ready_timer_.Stop();
    registry_.Reset();
    Observe(nullptr);
    auto callback = std::move(callback_);
    auto prompt = std::move(prompt_);
    CioExtensionInstallRequest* request = request_;
    request.canAccept = NO;
    if (request)
      [NSNotificationCenter.defaultCenter postNotificationName:@"CioExtensionInstallFinished"
                                                       object:request];
    // Let AppKit's button/sheet or tab-close stack unwind before installation
    // mutates Chromium's registry. The moved callback cannot run twice.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](std::unique_ptr<extensions::InstallPromptData> data,
                         extensions::ExtensionInstallPromptClient::DoneCallback done,
                         bool accept) {
          if (accept) data->OnDialogAccepted();
          else data->OnDialogCanceled();
          using Client = extensions::ExtensionInstallPromptClient;
          std::move(done).Run(Client::DoneCallbackPayload(
              accept ? Client::Result::ACCEPTED : Client::Result::USER_CANCELED));
        }, std::move(prompt), std::move(callback), accepted));
  }

  void WebContentsDestroyed() override {
    auto keep_alive = shared_from_this();
    Finish(false);
  }
  void OnExtensionUninstalled(content::BrowserContext*,
      const extensions::Extension* extension, extensions::UninstallReason) override {
    auto keep_alive = shared_from_this();
    if (prompt_ && extension->id() == prompt_->extension()->id()) Finish(false);
  }
  void OnShutdown(extensions::ExtensionRegistry*) override {
    auto keep_alive = shared_from_this();
    Finish(false);
  }
 private:
  std::unique_ptr<ExtensionInstallPromptShowParams> params_;
  extensions::ExtensionInstallPromptClient::DoneCallback callback_;
  std::unique_ptr<extensions::InstallPromptData> prompt_;
  base::ScopedObservation<extensions::ExtensionRegistry,
      extensions::ExtensionRegistryObserver> registry_{this};
  base::OneShotTimer ready_timer_;
  __weak CioExtensionInstallRequest* request_ = nil;
  __weak NSWindow* window_ = nil;
  bool presented_ = false;
  bool ready_ = false;
};

// Chromium's window-modal style assumes a Views-backed parent. Cio's AppKit
// window has no such bridge, so attach the original permission widget as a
// real sheet ourselves. Chromium still owns its contents and accept/cancel
// callbacks, including input protection and the complete permission list.
class InstallSheetObserver final : public views::WidgetObserver {
 public:
  InstallSheetObserver(views::Widget* widget, NSWindow* parent) : parent_(parent) {
    widget->AddObserver(this);
  }
  void OnWidgetClosing(views::Widget* widget) override { EndSheet(widget); }
  void OnWidgetDestroying(views::Widget* widget) override {
    EndSheet(widget);
    widget->RemoveObserver(this);
    delete this;
  }
 private:
  void EndSheet(views::Widget* widget) {
    NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
    if (window.sheetParent == parent_ && parent_)
      [parent_ endSheet:window];
  }
  __weak NSWindow* parent_;
};

void PresentInstalledExtension(base::WeakPtr<Profile> profile, std::string id) {
  if (!profile || profile->ShutdownStarted()) return;
  const auto* extension = extensions::ExtensionRegistry::Get(profile.get())->GetInstalledExtension(id);
  if (!extension) return;
  // Keep Chromium's signed extension preferences and install directory as the
  // only source of truth. Do not maintain a second shell-owned extension list.
  profile->GetPrefs()->CommitPendingWrite();
  NSWindow* window = cio::CioMainWindow();
  if (!window) return;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"已安装 %@", base::SysUTF8ToNSString(extension->name())];
  alert.informativeText = @"扩展程序保存在此浏览器资料中。可在扩展管理页调整设置。";
  [alert addButtonWithTitle:@"好"];
  [alert addButtonWithTitle:@"管理扩展程序"];
  [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
    if (response == NSAlertSecondButtonReturn)
      [NSNotificationCenter.defaultCenter postNotificationName:@"CioOpenExtensionManager" object:nil];
  }];
}
}

@implementation CioExtensionInstallRequest {
  std::shared_ptr<NativeInstallPrompt> _prompt;
}
@synthesize extensionName = _extensionName;
@synthesize permissionsHeading = _permissionsHeading;
@synthesize permissions = _permissions;
@synthesize acceptLabel = _acceptLabel;
@synthesize cancelLabel = _cancelLabel;
@synthesize parentWindow = _parentWindow;
@synthesize canAccept = _canAccept;
- (instancetype)initWithPrompt:(std::shared_ptr<NativeInstallPrompt>)prompt
                         parent:(NSWindow*)parent {
  self = [super init];
  if (!self) return nil;
  _prompt = std::move(prompt);
  const auto& data = _prompt->data();
  _extensionName = base::SysUTF8ToNSString(data.extension()->name());
  _permissionsHeading = base::SysUTF16ToNSString(data.GetPermissionsHeading());
  _acceptLabel = base::SysUTF16ToNSString(data.GetAcceptButtonLabel());
  _cancelLabel = base::SysUTF16ToNSString(data.GetAbortButtonLabel());
  _parentWindow = parent;
  NSMutableArray<NSString*>* permissions = [NSMutableArray array];
  auto messages = data.GetPermissions();
  for (size_t i = 0; i < messages.permissions.size(); ++i) {
    std::u16string text = messages.permissions[i];
    if (i < messages.details.size() && !messages.details[i].empty())
      text += u"\n" + messages.details[i];
    [permissions addObject:base::SysUTF16ToNSString(text)];
  }
  _permissions = [permissions copy];
  _prompt->SetRequest(self);
  return self;
}
- (void)didPresentInWindow:(NSWindow*)window { auto state = _prompt; state->Presented(window); }
- (void)accept { auto state = _prompt; state->Finish(true); }
- (void)cancel { auto state = _prompt; state->Finish(false); }
@end

namespace cio {
bool CanInteractWithExtensionPrompt(NSWindow* window) {
  if (!window || !window.isKeyWindow || !window.sheetParent ||
      !(window.occlusionState & NSWindowOcclusionStateVisible)) return false;
  // Views' PiP protector cannot observe an AppKit sheet. Reject interaction
  // while another Cio floating window obscures its confirmation controls.
  for (NSWindow* other in NSApp.orderedWindows) {
    if (other == window) break;
    if (other.isVisible && other.level > NSNormalWindowLevel &&
        NSIntersectsRect(other.frame, window.frame)) return false;
  }
  return true;
}

bool ShowExtensionInstallPrompt(
    std::unique_ptr<ExtensionInstallPromptShowParams>& params,
    extensions::ExtensionInstallPromptClient::DoneCallback& callback,
    std::unique_ptr<extensions::InstallPromptData>& prompt) {
  if (!IsHostedBrowser() || prompt->type() != extensions::InstallPromptData::INSTALL_PROMPT ||
      prompt->requires_parent_permission() || prompt->ShouldWithheldPermissionsOnDialogAccept())
    return false;
  auto state = std::make_shared<NativeInstallPrompt>(
      std::move(params), std::move(callback), std::move(prompt));
  NSWindow* parent = CioMainWindow();
  if (!parent) { state->Finish(false); return true; }
  CioExtensionInstallRequest* request = [[CioExtensionInstallRequest alloc]
      initWithPrompt:state parent:parent];
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioExtensionInstallRequested"
                                                   object:request];
  // A missing shell presenter releases the request and cancels the prompt.
  return true;
}

bool ShowExtensionInstallSheet(views::Widget* widget) {
  if (!IsHostedBrowser() || !CioMainWindow()) return false;
  NSWindow* parent = CioMainWindow();
  NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
  auto weak = widget->GetWeakPtr();
  new InstallSheetObserver(widget, parent);
  // Initialize Chromium's visibility/compositor before AppKit takes ownership
  // of presentation. The inactive show and sheet attachment share one turn.
  widget->ShowInactive();
  if (!weak) return true;
  [parent beginSheet:window completionHandler:^(NSModalResponse response) {
    // A parent closing or an external endSheet must also cancel the prompt.
    // Posting avoids destroying the Views widget inside an AppKit callback.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<views::Widget> prompt) {
          if (prompt) prompt->Close();
        }, weak));
  }];
  return true;
}

bool ShowExtensionInstalled(Profile* profile, const extensions::Extension* extension) {
  if (!IsHostedBrowser()) return false;
  // CrxInstaller reports UI success before registering the extension and its
  // granted permissions. Wait until that UI task unwinds before saving or
  // announcing success. A weak Profile also makes shutdown safe.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      &PresentInstalledExtension, profile->GetWeakPtr(), extension->id()));
  return true;
}

bool ShowExtensionInstallError(const extensions::CrxInstallError& error) {
  if (!IsHostedBrowser()) return false;
  // Cancellation is already reflected by the original Chromium install API.
  if (error.type() != extensions::CrxInstallErrorType::SANDBOXED_UNPACKER_FAILURE &&
      (error.detail() == extensions::CrxInstallErrorDetail::USER_CANCELED ||
       error.detail() == extensions::CrxInstallErrorDetail::USER_ABORTED)) return true;
  NSWindow* window = CioMainWindow();
  if (!window) return true;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"无法安装扩展程序";
  alert.informativeText = base::SysUTF16ToNSString(error.message());
  [alert beginSheetModalForWindow:window completionHandler:nil];
  return true;
}
}
