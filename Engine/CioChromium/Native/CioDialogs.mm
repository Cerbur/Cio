#include "chrome/browser/ui/cio/CioWindowHooks.h"
#include "chrome/browser/ui/cio/CioNativeRuntime.h"

#import <AppKit/AppKit.h>
#include <map>
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/external_protocol/external_protocol_handler.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/pref_names.h"
#include "chrome/grit/generated_resources.h"
#include "components/prefs/pref_service.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/common/result_codes.h"
#include "ui/base/l10n/l10n_util.h"

namespace {
struct Dialog {
  NSAlert* alert;
  NSTextField* input = nil;
  content::JavaScriptDialogManager::DialogClosedCallback callback;
  NSModalResponse accepted = NSAlertFirstButtonReturn;
  void Finish(bool accept, const std::u16string* override = nullptr) {
    if (!callback) return;
    std::u16string value = override ? *override :
        (input ? base::SysNSStringToUTF16(input.stringValue) : std::u16string());
    auto done = std::move(callback);
    if (alert.window.sheetParent)
      [alert.window.sheetParent endSheet:alert.window returnCode:NSModalResponseCancel];
    std::move(done).Run(accept, value);
  }
};

// Chrome Views sheets require NativeWidgetMac parents. Cio instead presents
// real AppKit sheets and resolves Chromium's original callback exactly once.
class DialogManager final : public content::JavaScriptDialogManager {
 public:
  void RunJavaScriptDialog(content::WebContents* contents,
      content::RenderFrameHost*, content::JavaScriptDialogType type,
      const std::u16string& message, const std::u16string& prompt,
      DialogClosedCallback callback, bool* suppressed) override {
    *suppressed = false;
    auto dialog = Create(contents, std::move(callback));
    dialog->alert.messageText = base::SysUTF8ToNSString(contents->GetLastCommittedURL().host());
    dialog->alert.informativeText = base::SysUTF16ToNSString(message);
    [dialog->alert addButtonWithTitle:@"OK"];
    if (type != content::JAVASCRIPT_DIALOG_TYPE_ALERT)
      [dialog->alert addButtonWithTitle:@"Cancel"];
    if (type == content::JAVASCRIPT_DIALOG_TYPE_PROMPT) {
      dialog->input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
      dialog->input.stringValue = base::SysUTF16ToNSString(prompt);
      dialog->alert.accessoryView = dialog->input;
    }
    Present(contents, dialog);
  }
  void RunBeforeUnloadDialog(content::WebContents* contents,
      content::RenderFrameHost*, bool, DialogClosedCallback callback) override {
    auto dialog = Create(contents, std::move(callback));
    dialog->alert.messageText = @"Leave this page?";
    dialog->alert.informativeText = @"Any unsaved changes may be lost.";
    [dialog->alert addButtonWithTitle:@"Stay"];
    [dialog->alert addButtonWithTitle:@"Leave"];
    dialog->accepted = NSAlertSecondButtonReturn;
    Present(contents, dialog);
    // Explicit test input, restricted to the existing integration driver.
    NSString* choice = NSProcessInfo.processInfo.environment[@"CIO_BEFOREUNLOAD_AUTORESPONSE"];
    if ([choice isEqualToString:@"accept"] || [choice isEqualToString:@"cancel"])
      dispatch_async(dispatch_get_main_queue(), ^{
        [dialog->alert.buttons[[choice isEqualToString:@"accept"] ? 1 : 0] performClick:nil];
      });
  }
  bool HandleJavaScriptDialog(content::WebContents* contents, bool accept,
      const std::u16string* value) override {
    auto found = dialogs_.find(contents);
    if (found == dialogs_.end() || !found->second->callback) return false;
    auto dialog = found->second;
    dialogs_.erase(found);
    dialog->Finish(accept, value);
    return true;
  }
  void CancelDialogs(content::WebContents* contents, bool) override {
    HandleJavaScriptDialog(contents, false, nullptr);
  }
 private:
  std::shared_ptr<Dialog> Create(content::WebContents* contents, DialogClosedCallback callback) {
    CancelDialogs(contents, false);
    auto dialog = std::make_shared<Dialog>();
    dialog->alert = [[NSAlert alloc] init];
    dialog->callback = std::move(callback);
    dialogs_[contents] = dialog;
    return dialog;
  }
  void Present(content::WebContents* contents, std::shared_ptr<Dialog> dialog) {
    NSWindow* window = cio::CioMainWindow();
    if (!window) { dialogs_.erase(contents); dialog->Finish(false); return; }
    [dialog->alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
      auto found = dialogs_.find(contents);
      if (found != dialogs_.end() && found->second == dialog) dialogs_.erase(found);
      dialog->Finish(response == dialog->accepted);
    }];
  }
  std::map<content::WebContents*, std::shared_ptr<Dialog>> dialogs_;
};

std::map<content::WebContents*, NSAlert*>& HungDialogs() {
  static base::NoDestructor<std::map<content::WebContents*, NSAlert*>> dialogs;
  return *dialogs;
}

// Cio's AppKit window has no NativeWidgetMac parent for Chrome Views sheets.
// Observe the requesting page so a prompt cannot survive navigation or closure.
class ExternalProtocolPrompt final : public content::WebContentsObserver {
 public:
  explicit ExternalProtocolPrompt(content::WebContents* contents)
      : content::WebContentsObserver(contents), alert([[NSAlert alloc] init]) {}
  void PrimaryPageChanged(content::Page&) override { Cancel(); }
  void WebContentsDestroyed() override { Cancel(); }
  void Cancel() {
    cancelled = true;
    if (alert.window.sheetParent)
      [alert.window.sheetParent endSheet:alert.window returnCode:NSModalResponseCancel];
  }
  NSAlert* alert;
  bool cancelled = false;
};
}

namespace cio {
content::JavaScriptDialogManager* NativeJavaScriptDialogs() {
  if (!IsHostedBrowser()) return nullptr;
  static base::NoDestructor<DialogManager> manager;
  return manager.get();
}
bool ShowExternalProtocolDialog(content::WebContents* contents, const GURL& url,
    const std::u16string& program_name, const std::optional<url::Origin>& origin,
    content::WeakDocumentPtr initiator_document) {
  if (!IsHostedBrowser()) return false;
  NSWindow* window = CioMainWindow();
  if (!window) return true;
  auto prompt = std::make_shared<ExternalProtocolPrompt>(contents);
  NSAlert* alert = prompt->alert;
  alert.messageText = base::SysUTF16ToNSString(l10n_util::GetStringFUTF16(
      IDS_EXTERNAL_PROTOCOL_TITLE, program_name));
  alert.informativeText = base::SysUTF16ToNSString(
      origin && !origin->opaque()
          ? l10n_util::GetStringFUTF16(IDS_EXTERNAL_PROTOCOL_MESSAGE_WITH_INITIATING_ORIGIN,
                url_formatter::FormatOriginForSecurityDisplay(*origin))
          : l10n_util::GetStringUTF16(IDS_EXTERNAL_PROTOCOL_MESSAGE));
  [alert addButtonWithTitle:base::SysUTF16ToNSString(l10n_util::GetStringFUTF16(
      IDS_EXTERNAL_PROTOCOL_OK_BUTTON_TEXT, program_name))];
  [alert addButtonWithTitle:base::SysUTF16ToNSString(
      l10n_util::GetStringUTF16(IDS_EXTERNAL_PROTOCOL_CANCEL_BUTTON_TEXT))];
  // Return must not open an external application accidentally.
  alert.buttons[0].keyEquivalent = @"";
  alert.buttons[1].keyEquivalent = @"\r";
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  NSButton* remember = nil;
  if (profile->GetPrefs()->GetBoolean(prefs::kExternalProtocolDialogShowAlwaysOpenCheckbox) &&
      ExternalProtocolHandler::MayRememberAllowDecisionsForThisOrigin(
          origin ? &*origin : nullptr)) {
    remember = [NSButton checkboxWithTitle:base::SysUTF16ToNSString(
        l10n_util::GetStringFUTF16(IDS_EXTERNAL_PROTOCOL_CHECKBOX_PER_ORIGIN_TEXT,
            url_formatter::FormatOriginForSecurityDisplay(*origin,
                url_formatter::SchemeDisplay::OMIT_CRYPTOGRAPHIC)))
        target:nil action:nil];
    [remember sizeToFit];
    alert.accessoryView = remember;
  }
  auto weak = contents->GetWeakPtr();
  // Objective-C blocks retain C++ reference parameters as references. Own the
  // request values after Chromium's one-shot presentation callback returns.
  GURL target_url = url;
  auto requesting_origin = origin;
  [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
    bool accepted = response == NSAlertFirstButtonReturn && !prompt->cancelled && weak;
    bool remembered = accepted && remember && remember.state == NSControlStateValueOn;
    ExternalProtocolHandler::RecordHandleStateMetrics(remembered,
        accepted ? ExternalProtocolHandler::DONT_BLOCK : ExternalProtocolHandler::BLOCK);
    if (!accepted) return;
    if (remembered)
      ExternalProtocolHandler::SetBlockState(target_url.GetScheme(), *requesting_origin,
          ExternalProtocolHandler::DONT_BLOCK,
          Profile::FromBrowserContext(weak->GetBrowserContext()));
    ExternalProtocolHandler::LaunchUrlWithoutSecurityCheck(target_url, weak.get(), initiator_document);
  }];
  return true;
}
bool HideHungRenderer(content::WebContents* contents) {
  if (!IsHostedBrowser()) return false;
  auto found = HungDialogs().find(contents);
  if (found != HungDialogs().end()) {
    NSAlert* alert = found->second;
    HungDialogs().erase(found);
    if (alert.window.sheetParent)
      [alert.window.sheetParent endSheet:alert.window returnCode:NSModalResponseCancel];
  }
  return true;
}
bool ShowHungRenderer(content::WebContents* contents, base::RepeatingClosure restart) {
  if (!IsHostedBrowser()) return false;
  if (HungDialogs().contains(contents) || !CioMainWindow()) return true;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Page unresponsive";
  alert.informativeText = @"You can wait for this page or stop it.";
  [alert addButtonWithTitle:@"Wait"];
  [alert addButtonWithTitle:@"Stop page"];
  HungDialogs()[contents] = alert;
  auto weak = contents->GetWeakPtr();
  [alert beginSheetModalForWindow:CioMainWindow() completionHandler:^(NSModalResponse response) {
    auto found = HungDialogs().find(contents);
    if (found == HungDialogs().end() || found->second != alert) return;
    HungDialogs().erase(found);
    if (!weak) return;
    if (response == NSAlertSecondButtonReturn)
      weak->GetPrimaryMainFrame()->GetProcess()->Shutdown(content::RESULT_CODE_HUNG);
    else if (response == NSAlertFirstButtonReturn) restart.Run();
  }];
  return true;
}
}
