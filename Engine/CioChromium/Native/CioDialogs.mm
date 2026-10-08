#include "chrome/browser/ui/cio/CioWindowHooks.h"
#include "chrome/browser/ui/cio/CioNativeRuntime.h"

#import <AppKit/AppKit.h>
#include <map>
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/result_codes.h"

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
}

namespace cio {
content::JavaScriptDialogManager* NativeJavaScriptDialogs() {
  if (!IsHostedBrowser()) return nullptr;
  static base::NoDestructor<DialogManager> manager;
  return manager.get();
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
