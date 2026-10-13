#include "chrome/browser/ui/cio/CioPermissions.h"
#include "chrome/browser/ui/cio/CioWindowHooks.h"
#import <AppKit/AppKit.h>
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_util.h"
#include "components/permissions/request_type.h"
#include "content/public/browser/web_contents.h"
#include "ui/display/types/display_constants.h"
#include "url/origin.h"

namespace {
// The upstream request manager still owns policy, request lifetime, persistence,
// one-time grants and tab switching. This adapter only presents its decisions.
class NativePermissionPrompt final : public permissions::PermissionPrompt {
 public:
  NativePermissionPrompt(content::WebContents* contents, Delegate* delegate,
                         base::ScopedClosureRunner fullscreen_blocker)
      : delegate_(delegate->GetWeakPtr()), fullscreen_blocker_(std::move(fullscreen_blocker)) {
    cursor_scope_ = contents->CreateDisallowCustomCursorScope(0);
    alert_ = [[NSAlert alloc] init];
    alert_.messageText = base::SysUTF8ToNSString(url::Origin::Create(delegate->GetRequestingOrigin()).Serialize());
    NSMutableArray<NSString*>* descriptions = [NSMutableArray array];
    bool temporary = !delegate->Requests().empty();
    bool location = false;
    for (auto& request : delegate->Requests()) {
      [descriptions addObject:base::SysUTF16ToNSString(request->GetMessageTextFragment())];
      temporary &= permissions::PermissionUtil::DoesSupportTemporaryGrants(request->GetContentSettingsType());
      location |= request->request_type() == permissions::RequestType::kGeolocation;
    }
    NSString* embedding = base::SysUTF8ToNSString(url::Origin::Create(delegate->GetEmbeddingOrigin()).Serialize());
    alert_.informativeText = [NSString stringWithFormat:@"Wants to:\n%@%@",
        [descriptions componentsJoinedByString:@"\n"],
        url::Origin::Create(delegate->GetRequestingOrigin()) != url::Origin::Create(delegate->GetEmbeddingOrigin())
            ? [NSString stringWithFormat:@"\n\nRequested within %@", embedding] : @""];
    [alert_ addButtonWithTitle:@"Block"];
    [alert_ addButtonWithTitle:@"Allow"];
    if (temporary) [alert_ addButtonWithTitle:@"Allow this time"];
    // Return never grants permission; allowing requires an explicit button click.
    for (NSButton* button in alert_.buttons) button.keyEquivalent = @"";
    alert_.buttons[0].keyEquivalent = @"\r";
    if (location) {
      accuracy_ = [NSButton checkboxWithTitle:@"Use precise location" target:nil action:nil];
      accuracy_.state = delegate->GetInitialGeolocationAccuracySelection() == GeolocationAccuracy::kPrecise
          ? NSControlStateValueOn : NSControlStateValueOff;
      alert_.accessoryView = accuracy_;
    }
    auto weak = weak_factory_.GetWeakPtr();
    dispatch_async(dispatch_get_main_queue(), ^{ if (weak) weak->Present(); });
  }
  ~NativePermissionPrompt() override {
    weak_factory_.InvalidateWeakPtrs();
    if (alert_.window.sheetParent)
      [alert_.window.sheetParent endSheet:alert_.window returnCode:NSModalResponseCancel];
    [alert_.window orderOut:nil];
  }
  bool UpdateAnchor() override { return true; }
  TabSwitchingBehavior GetTabSwitchingBehavior() override { return kDestroyPromptButKeepRequestPending; }
  permissions::PermissionPromptDisposition GetPromptDisposition() const override {
    return permissions::PermissionPromptDisposition::MODAL_DIALOG;
  }
  bool IsAskPrompt() const override { return true; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override {
    if (!alert_.window.isVisible) return std::nullopt;
    NSRect frame = alert_.window.frame;
    return gfx::Rect(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
  }
  bool ShouldFinalizeRequestAfterDecided() const override { return true; }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants() const override { return {}; }
  std::optional<permissions::feature_params::PermissionElementPromptPosition> GetPromptPosition() const override { return std::nullopt; }
 private:
  void Present() {
    if (!delegate_) return;
    NSWindow* parent = delegate_->GetAssociatedWebContents()->GetNativeView().GetNativeNSView().window;
    if (!parent) { delegate_->Dismiss(std::monostate{}); return; }
    delegate_->SetPromptShown();
    auto weak = weak_factory_.GetWeakPtr();
    [alert_ beginSheetModalForWindow:parent completionHandler:^(NSModalResponse response) {
      if (!weak || !weak->delegate_) return;
      auto delegate = weak->delegate_;
      PromptOptions options = std::monostate{};
      if (weak->accuracy_) options = GeolocationPromptOptions{
          weak->accuracy_.state == NSControlStateValueOn ? GeolocationAccuracy::kPrecise : GeolocationAccuracy::kApproximate};
      delegate->SetDecisionTime();
      // A decision may synchronously destroy this prompt. Do not touch it again.
      if (response == NSAlertSecondButtonReturn) delegate->Accept(options);
      else if (response == NSAlertThirdButtonReturn) delegate->AcceptThisTime(options);
      else if (response == NSAlertFirstButtonReturn) delegate->Deny(options);
      else delegate->Dismiss(options);
    }];
  }
  base::WeakPtr<Delegate> delegate_;
  NSAlert* alert_;
  NSButton* accuracy_ = nil;
  base::ScopedClosureRunner fullscreen_blocker_;
  base::ScopedClosureRunner cursor_scope_;
  base::WeakPtrFactory<NativePermissionPrompt> weak_factory_{this};
};
}
namespace cio {
std::unique_ptr<permissions::PermissionPrompt> CreatePermissionPrompt(
    content::WebContents* contents, permissions::PermissionPrompt::Delegate* delegate) {
  if (delegate->ShouldDropCurrentRequestIfCannotShowQuietly()) return nullptr;
  auto weak_delegate = delegate->GetWeakPtr();
  auto blocker = contents->ForSecurityDropFullscreen(display::kInvalidDisplayId);
  // Exiting fullscreen can synchronously destroy the page or request manager.
  if (!blocker || !weak_delegate) return nullptr;
  return std::make_unique<NativePermissionPrompt>(contents, delegate, std::move(*blocker));
}
}
