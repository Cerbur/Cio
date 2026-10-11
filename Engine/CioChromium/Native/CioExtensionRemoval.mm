#include "chrome/browser/ui/cio/CioExtensionRemoval.h"
#include "chrome/browser/ui/cio/CioExtensionUI.h"
#include "chrome/browser/ui/cio/CioNativeRuntime.h"
#include "chrome/browser/ui/cio/CioWindowHooks.h"
#import "chrome/browser/ui/cio/CioExtensionRemovalRequest.h"

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/timer/timer.h"
#include "chrome/grit/generated_resources.h"
#include "extensions/browser/ui_util.h"
#include "ui/base/l10n/l10n_util.h"

@interface CioExtensionRemovalRequest ()
@property(nonatomic, readwrite) BOOL canAccept;
- (instancetype)initWithName:(NSString*)name message:(NSString*)message
              reportAbuseLabel:(NSString*)label parent:(NSWindow*)parent
              completion:(base::OnceCallback<void(bool, bool)>)completion;
- (void)invalidate;
- (void)finish:(BOOL)accepted reportAbuse:(BOOL)reportAbuse;
@end

@implementation CioExtensionRemovalRequest {
  base::OnceCallback<void(bool, bool)> _completion;
  base::OneShotTimer _inputProtection;
  __weak NSWindow* _presentedWindow;
  BOOL _finished;
  BOOL _presented;
}
@synthesize extensionName = _extensionName;
@synthesize message = _message;
@synthesize reportAbuseLabel = _reportAbuseLabel;
@synthesize parentWindow = _parentWindow;
@synthesize canAccept = _canAccept;

- (instancetype)initWithName:(NSString*)name message:(NSString*)message
              reportAbuseLabel:(NSString*)label parent:(NSWindow*)parent
              completion:(base::OnceCallback<void(bool, bool)>)completion {
  self = [super init];
  if (!self) return nil;
  _extensionName = [name copy];
  _message = [message copy];
  _reportAbuseLabel = [label copy];
  _parentWindow = parent;
  _completion = std::move(completion);
  return self;
}
- (void)didPresentInWindow:(NSWindow*)window {
  if (_finished || _presented) return;
  _presented = YES;
  _presentedWindow = window;
  // Operational input protection; independent of visual animation speed.
  constexpr auto kInputProtectionDelay = base::Milliseconds(500);
  _inputProtection.Start(FROM_HERE, kInputProtectionDelay,
      base::BindOnce([](CioExtensionRemovalRequest* request) {
        request.canAccept = YES;
      }, self));
}
- (void)acceptWithReportAbuse:(BOOL)reportAbuse {
  [self finish:YES reportAbuse:reportAbuse];
}
- (void)cancel { [self finish:NO reportAbuse:NO]; }
- (void)finish:(BOOL)accepted reportAbuse:(BOOL)reportAbuse {
  if (_finished || !_completion) return;
  if (accepted && (!self.canAccept ||
      !cio::CanInteractWithExtensionPrompt(_presentedWindow))) return;
  auto completion = std::move(_completion);
  [self invalidate];
  // Run the original delegate path after AppKit's button/sheet stack unwinds.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce(std::move(completion), bool(accepted), bool(reportAbuse)));
}
- (void)invalidate {
  if (_finished) return;
  _finished = YES;
  _inputProtection.Stop();
  _completion.Reset();
  self.canAccept = NO;
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioExtensionRemovalFinished"
                                                   object:self];
}
@end

namespace {
// The base class keeps registry/profile observation, uninstall policy, metrics,
// uninstall URL handling, abuse reporting and the caller's delegate result.
class NativeExtensionUninstallDialog final : public extensions::ExtensionUninstallDialog {
 public:
  NativeExtensionUninstallDialog(Profile* profile, gfx::NativeWindow parent, Delegate* delegate)
      : ExtensionUninstallDialog(profile, parent, delegate) {}
  ~NativeExtensionUninstallDialog() override { [request_ invalidate]; }
 private:
  void Show() override {
    NSWindow* window = cio::CioMainWindow();
    if (!window) { OnDialogClosed(CLOSE_ACTION_CANCELED); return; }
    NSString* name = base::SysUTF16ToNSString(
        extensions::ui_util::GetFixupExtensionNameForUIDisplay(extension()->name()));
    NSString* message = @"此扩展将从 Cio 中移除。";
    NSString* checkbox = nil;
    if (triggering_extension()) {
      auto trigger_name = extensions::ui_util::GetFixupExtensionNameForUIDisplay(
          triggering_extension()->name());
      NSString* trigger = base::SysUTF16ToNSString(l10n_util::GetStringFUTF16(
          IDS_EXTENSION_PROMPT_UNINSTALL_TRIGGERED_BY_EXTENSION, trigger_name));
      message = [message stringByAppendingFormat:@"\n%@", trigger];
    }
    if (ShouldShowCheckbox()) {
      checkbox = base::SysUTF16ToNSString(triggering_extension()
          ? l10n_util::GetStringFUTF16(IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE_FROM_EXTENSION,
              extensions::ui_util::GetFixupExtensionNameForUIDisplay(extension()->name()))
          : l10n_util::GetStringUTF16(IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE));
    }
    request_ = [[CioExtensionRemovalRequest alloc] initWithName:name message:message
        reportAbuseLabel:checkbox parent:window completion:base::BindOnce(
          [](base::WeakPtr<extensions::ExtensionUninstallDialog> dialog,
             bool accepted, bool report) {
            if (dialog) dialog->OnDialogClosed(!accepted ? CLOSE_ACTION_CANCELED
                : report ? CLOSE_ACTION_UNINSTALL_AND_CHECKBOX_CHECKED : CLOSE_ACTION_UNINSTALL);
          }, AsWeakPtr())];
    [NSNotificationCenter.defaultCenter postNotificationName:@"CioExtensionRemovalRequested"
                                                     object:request_];
  }
  void Close() override { [request_ cancel]; }
  CioExtensionRemovalRequest* request_ = nil;
};
}

namespace cio {
std::unique_ptr<extensions::ExtensionUninstallDialog> CreateExtensionUninstallDialog(
    Profile* profile, gfx::NativeWindow parent,
    extensions::ExtensionUninstallDialog::Delegate* delegate) {
  if (!IsHostedBrowser()) return nullptr;
  return std::make_unique<NativeExtensionUninstallDialog>(profile, parent, delegate);
}
}
