#import <AppKit/AppKit.h>
#include "chrome/browser/ui/cio/CioPasswords.h"
#include "chrome/browser/ui/cio/CioWindowHooks.h"
#include <algorithm>
#include <functional>
#include <map>
#include <set>
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/autofill/autofill_popup_controller.h"
#include "chrome/browser/ui/autofill/autofill_popup_view.h"
#include "chrome/browser/ui/views/autofill/popup/popup_view_utils.h"
#include "chrome/browser/ui/passwords/bubble_controllers/save_update_bubble_controller.h"
#include "chrome/browser/ui/passwords/credential_manager_dialog_controller.h"
#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"
#include "chrome/browser/ui/passwords/password_dialog_prompts.h"
#include "chrome/browser/ui/passwords/password_generation_popup_controller.h"
#include "chrome/browser/ui/passwords/password_generation_popup_view.h"
#include "chrome/browser/ui/passwords/password_cross_domain_confirmation_popup_controller_interface.h"
#include "chrome/browser/ui/passwords/password_cross_domain_confirmation_popup_view.h"
#include "chrome/browser/ui/passwords/passwords_model_delegate.h"
#include "components/autofill/core/browser/filling/filling_product.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/device_reauth/device_authenticator.h"
#include "components/password_manager/core/browser/password_form.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/weak_document_ptr.h"
#include "ui/events/keycodes/keyboard_codes.h"

@interface CioPasswordAction : NSObject
@property(nonatomic, copy) void (^invoke)(void);
- (void)perform:(id)sender;
@end
@implementation CioPasswordAction
@synthesize invoke = _invoke;
- (void)perform:(id)sender { if (_invoke) _invoke(); }
@end
@interface CioPasswordPanel : NSPanel
@property(nonatomic) BOOL acceptsKeyboard;
@end
@implementation CioPasswordPanel
@synthesize acceptsKeyboard = _acceptsKeyboard;
- (BOOL)canBecomeKeyWindow { return self.acceptsKeyboard; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

namespace cio {
namespace {
class PasswordSurface;
std::set<PasswordSurface*>& Surfaces() { static auto* value = new std::set<PasswordSurface*>; return *value; }
std::map<content::WebContents*, PasswordSurface*>& Bubbles() {
  static auto* value = new std::map<content::WebContents*, PasswordSurface*>; return *value;
}

bool Eligible(content::WebContents* contents) {
  return contents && CanPresentPasswordUI(contents) &&
      ChromiumPasswordsEnabled(Profile::FromBrowserContext(contents->GetBrowserContext()));
}

// A panel belongs to one real WebContents and the documents that requested it.
// The system owns material, focus and transitions. No form parsing, filling,
// credential storage or cryptography is implemented in the shell.
class PasswordSurface : public content::WebContentsObserver {
 public:
  PasswordSurface(content::WebContents* contents, bool keyboard = false)
      : WebContentsObserver(contents), primary_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
        frame_(contents->GetFocusedFrame() ? contents->GetFocusedFrame()->GetWeakDocumentPtr() : primary_),
        lease_(1) {
    Surfaces().insert(this);
    panel_ = [[CioPasswordPanel alloc] initWithContentRect:NSMakeRect(0, 0, 350, 1)
        styleMask:NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    panel_.acceptsKeyboard = keyboard;
    panel_.releasedWhenClosed = NO;
    panel_.hidesOnDeactivate = YES;
    panel_.floatingPanel = YES;
    panel_.level = NSFloatingWindowLevel;
    auto* material = [[NSVisualEffectView alloc] initWithFrame:panel_.contentView.bounds];
    material.material = NSVisualEffectMaterialPopover;
    material.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    material.state = NSVisualEffectStateActive;
    panel_.contentView = material;
    stack_ = [[NSStackView alloc] init];
    stack_.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack_.alignment = NSLayoutAttributeLeading;
    stack_.spacing = 10;
    scroll_ = [[NSScrollView alloc] init];
    scroll_.drawsBackground = NO;
    scroll_.hasVerticalScroller = YES;
    scroll_.autohidesScrollers = YES;
    scroll_.translatesAutoresizingMaskIntoConstraints = NO;
    scroll_.documentView = stack_;
    [material addSubview:scroll_];
    [NSLayoutConstraint activateConstraints:@[
      [scroll_.leadingAnchor constraintEqualToAnchor:material.leadingAnchor constant:16],
      [scroll_.trailingAnchor constraintEqualToAnchor:material.trailingAnchor constant:-16],
      [scroll_.topAnchor constraintEqualToAnchor:material.topAnchor constant:16],
      [scroll_.bottomAnchor constraintEqualToAnchor:material.bottomAnchor constant:-16]
    ]];
    Text(base::SysUTF8ToNSString(contents->GetLastCommittedURL().host()), NO);
    auto weak = weak_factory_.GetWeakPtr();
    deactivation_ = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification
        object:NSApp queue:nil usingBlock:^(NSNotification*) { if (weak) weak->Cancel(); }];
    window_change_ = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification
        object:contents->GetNativeView().GetNativeNSView().window queue:nil
        usingBlock:^(NSNotification*) { if (weak) weak->Cancel(); }];
  }
  ~PasswordSurface() override {
    CloseNative();
    [NSNotificationCenter.defaultCenter removeObserver:deactivation_];
    [NSNotificationCenter.defaultCenter removeObserver:window_change_];
    for (CioPasswordAction* action in actions_) action.invoke = nil;
    weak_factory_.InvalidateWeakPtrs();
  }
  content::WebContents* contents() const { return web_contents(); }
  bool HasFocus() const { return panel_.isKeyWindow; }
  bool Usable() const {
    const bool same = primary_.AsRenderFrameHostIfValid() && frame_.AsRenderFrameHostIfValid();
    return lease_.CanAct(same ? 1 : 0, CanPresentPasswordUI(web_contents()),
        web_contents() && ChromiumPasswordsEnabled(Profile::FromBrowserContext(web_contents()->GetBrowserContext())));
  }
  void CloseNative() {
    lease_.Cancel();
    Surfaces().erase(this);
    if (panel_.parentWindow) [panel_.parentWindow removeChildWindow:panel_];
    [panel_ orderOut:nil];
    // Prevent retained AppKit controls from invoking an old C++ owner.
    for (CioPasswordAction* action in actions_) action.invoke = nil;
  }
  bool OverlapsPIP() const {
    NSRect frame = panel_.frame;
    const CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    return autofill::BoundsOverlapWithPictureInPictureWindow(gfx::Rect(
        NSMinX(frame), top - NSMaxY(frame), NSWidth(frame), NSHeight(frame)));
  }
  virtual void Cancel() = 0;
  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() ||
        navigation->GetRenderFrameHost() == frame_.AsRenderFrameHostIfValid()) Cancel();
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE) Cancel();
  }
  void WebContentsDestroyed() override { Cancel(); }
  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    if (!frame_.AsRenderFrameHostIfValid() || frame == frame_.AsRenderFrameHostIfValid()) Cancel();
  }
  void Text(NSString* value, bool heading = false) {
    auto* label = [NSTextField wrappingLabelWithString:value ?: @""];
    label.font = heading ? [NSFont boldSystemFontOfSize:NSFont.systemFontSize] : [NSFont systemFontOfSize:NSFont.systemFontSize];
    [stack_ addArrangedSubview:label];
  }
  NSButton* Button(NSString* title, std::function<void()> callback) {
    auto* action = [[CioPasswordAction alloc] init];
    auto weak = weak_factory_.GetWeakPtr();
    action.invoke = ^{ if (weak && weak->Usable()) callback(); };
    [actions_ addObject:action];
    auto* button = [NSButton buttonWithTitle:title ?: @"" target:action action:@selector(perform:)];
    [stack_ addArrangedSubview:button];
    return button;
  }
  bool Present(const gfx::RectF* element = nullptr) {
    if (!Usable()) return false;
    NSView* view = web_contents()->GetNativeView().GetNativeNSView();
    NSWindow* window = view.window;
    if (!window || window.attachedSheet) return false;
    [stack_ layoutSubtreeIfNeeded];
    stack_.frame = NSMakeRect(0, 0, 318, stack_.fittingSize.height);
    [stack_ layoutSubtreeIfNeeded];
    const CGFloat document_height = stack_.fittingSize.height;
    stack_.frame = NSMakeRect(0, 0, 318, document_height);
    CGFloat height = std::max<CGFloat>(90, document_height + 32);
    NSRect area = [window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
    height = std::min<CGFloat>(height, NSHeight(area) - 24);
    NSRect target = NSMakeRect(NSMinX(area) + (NSWidth(area) - 350) / 2,
                              NSMaxY(area) - height - 12, 350, height);
    if (element) {
      // Chromium screen coordinates use the primary display's top-left.
      const CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
      target.origin.x = std::clamp<CGFloat>(element->x(), NSMinX(area), std::max(NSMinX(area), NSMaxX(area) - 350));
      NSRect field = NSMakeRect(element->x(), top - element->bottom(), element->width(), element->height());
      if (!NSIntersectsRect(field, area)) return false;
      target.origin.y = std::max(NSMinY(area), top - element->bottom() - height);
    }
    if (NSWidth(area) < 350 || height < 90) return false;
    [panel_ setFrame:target display:YES];
    if (OverlapsPIP()) return false;
    if (panel_.parentWindow != window) [window addChildWindow:panel_ ordered:NSWindowAbove];
    [panel_.contentView layoutSubtreeIfNeeded];
    if (!stack_.isFlipped) [scroll_.contentView scrollToPoint:NSMakePoint(0,
        std::max<CGFloat>(0, document_height - scroll_.contentView.bounds.size.height))];
    [panel_ orderFront:nil];
    return true;
  }
 protected:
  NSStackView* stack_;
  NSScrollView* scroll_;
  CioPasswordPanel* panel_;
  NSMutableArray<CioPasswordAction*>* actions_ = [[NSMutableArray alloc] init];
  content::WeakDocumentPtr primary_;
  content::WeakDocumentPtr frame_;
  PasswordRequestLease lease_;
  id deactivation_;
  id window_change_;
  base::WeakPtrFactory<PasswordSurface> weak_factory_{this};
};

class SaveSurface final : public PasswordSurface {
 public:
  SaveSurface(content::WebContents* contents, bool user_action)
      : PasswordSurface(contents, true), controller_(std::make_unique<SaveUpdateBubbleController>(
          PasswordsModelDelegateFromWebContents(contents), user_action
              ? PasswordBubbleControllerBase::DisplayReason::kUserAction
              : PasswordBubbleControllerBase::DisplayReason::kAutomatic)) {
    Bubbles()[contents] = this;
    Text(base::SysUTF16ToNSString(controller_->GetTitle()), true);
    Text(@"账号");
    username_ = [[NSTextField alloc] init];
    username_.stringValue = base::SysUTF16ToNSString(controller_->pending_password().username_value);
    username_.placeholderString = @"用户名";
    [username_ setAccessibilityLabel:@"账号"];
    [stack_ addArrangedSubview:username_];
    [username_.widthAnchor constraintEqualToAnchor:stack_.widthAnchor].active = YES;
    Text(@"密码");
    password_ = [[NSSecureTextField alloc] init];
    password_.stringValue = base::SysUTF16ToNSString(controller_->pending_password().password_value);
    [password_ setAccessibilityLabel:@"密码（隐藏）"];
    [stack_ addArrangedSubview:password_];
    [password_.widthAnchor constraintEqualToAnchor:stack_.widthAnchor].active = YES;
    Button(controller_->IsCurrentStateUpdate() ? @"更新密码" : @"保存密码", [this] { Finish(0); }).keyEquivalent = @"\r";
    Button(@"暂不", [this] { Finish(1); }).keyEquivalent = @"\e";
    if (!controller_->IsCurrentStateUpdate()) Button(@"此网站不保存", [this] { Finish(2); });
  }
  ~SaveSurface() override {
    auto found = Bubbles().find(contents());
    if (found != Bubbles().end() && found->second == this) Bubbles().erase(found);
    // Erase and hide before controller notifications can synchronously re-enter.
    CloseNative();
    if (controller_) controller_->OnBubbleClosing();
    username_.stringValue = @"";
    password_.stringValue = @"";
  }
  void Cancel() override { delete this; }
 private:
  void Finish(int choice) {
    if (!lease_.Complete(1, CanPresentPasswordUI(contents()), Eligible(contents()))) return;
    auto controller = std::move(controller_);
    auto username = base::SysNSStringToUTF16(username_.stringValue);
    auto password = base::SysNSStringToUTF16(password_.stringValue);
    delete this;
    if (choice == 0) {
      controller->OnCredentialEdited(std::move(username), std::move(password));
      controller->OnSaveClicked();
    } else if (choice == 1) controller->OnNotNowClicked();
    else controller->OnNeverForThisSiteClicked();
    controller->OnBubbleClosing();
  }
  std::unique_ptr<SaveUpdateBubbleController> controller_;
  NSTextField* username_;
  NSSecureTextField* password_;
};

// Confirm generated-password persistence using the same model's bubble lifetime.
class ConfirmationSurface final : public PasswordSurface {
 public:
  explicit ConfirmationSurface(content::WebContents* contents)
      : PasswordSurface(contents), delegate_(PasswordsModelDelegateFromWebContents(contents)) {
    Bubbles()[contents] = this;
    delegate_->OnBubbleShown();
    Text(@"密码已由 Chromium 保存", true);
    Text(base::SysUTF16ToNSString(delegate_->GetPendingPassword().username_value));
    Button(@"好", [this] { Cancel(); });
  }
  ~ConfirmationSurface() override {
    auto found = Bubbles().find(contents());
    if (found != Bubbles().end() && found->second == this) Bubbles().erase(found);
    CloseNative();
    if (delegate_) delegate_->OnBubbleHidden();
  }
  void Cancel() override { delete this; }
 private:
  base::WeakPtr<PasswordsModelDelegate> delegate_;
};

class SuggestionsSurface final : public autofill::AutofillPopupView, public PasswordSurface {
 public:
  explicit SuggestionsSurface(base::WeakPtr<autofill::AutofillPopupController> controller)
      : PasswordSurface(controller->GetWebContents()), controller_(controller) {}
  bool Show(autofill::AutoselectFirstSuggestion select) override {
    Rebuild();
    if (!Present(&controller_->element_bounds())) { Cancel(); return false; }
    if (*select) SelectNext(1);
    // Keep Chromium's real input-protection barrier, including its 500ms idle
    // requirement. Native views must report their first paint to the controller.
    [panel_.contentView displayIfNeeded];
    controller_->OnPopupPainted();
    return true;
  }
  void Hide() override { delete this; }
  void Cancel() override {
    CloseNative();
    auto controller = controller_;
    if (controller) controller->Hide(autofill::SuggestionHidingReason::kTabGone);
    else delete this;
  }
  bool HandleKeyPressEvent(const input::NativeWebKeyboardEvent& event) override {
    if (!Usable() || PasswordIMEComposing(contents())) return false;
    if (event.GetType() != blink::WebInputEvent::Type::kRawKeyDown &&
        event.GetType() != blink::WebInputEvent::Type::kKeyDown) return false;
    switch (event.windows_key_code) {
      case ui::VKEY_UP: SelectNext(-1); return true;
      case ui::VKEY_DOWN: SelectNext(1); return true;
      case ui::VKEY_RETURN:
        if (selected_ >= 0) {
          auto controller = controller_;
          if (!controller->GetSuggestionAt(selected_).children.empty()) {
            controller->OpenSubPopup(controller->element_bounds(), controller->GetSuggestionAt(selected_).children,
                                     autofill::AutoselectFirstSuggestion(true));
          } else controller->AcceptSuggestion(selected_, autofill::AutofillMetrics::SuggestionAcceptedMethod::kKeyboard);
          return true;
        }
        return false;
      case ui::VKEY_ESCAPE:
        controller_->Hide(autofill::SuggestionHidingReason::kUserAborted); return true;
      default: return false;
    }
  }
  void OnSuggestionsChanged(bool) override {
    if (!Usable()) { Cancel(); return; }
    Rebuild();
    if (!Present(&controller_->element_bounds())) Cancel();
  }
  bool OverlapsWithPictureInPictureWindow() const override { return OverlapsPIP(); }
  void AxAnnounce(const std::u16string& text) override {
    NSAccessibilityPostNotificationWithUserInfo(panel_.contentView,
        NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey: base::SysUTF16ToNSString(text),
          NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh)});
  }
  std::optional<int32_t> GetAxUniqueId() override { return std::nullopt; }
  base::WeakPtr<autofill::AutofillPopupView> CreateSubPopupView(
      base::WeakPtr<autofill::AutofillPopupController> controller) override {
    return CreatePasswordSuggestions(controller);
  }
  std::optional<size_t> GetIndexOfSubPopupAnchorSuggestion() const override {
    return selected_ >= 0 ? std::make_optional<size_t>(selected_) : std::nullopt;
  }
  bool HasFocus() const override { return PasswordSurface::HasFocus(); }
  base::WeakPtr<autofill::AutofillPopupView> GetWeakPtr() override { return view_weak_factory_.GetWeakPtr(); }
 private:
  bool Selectable(int index) const {
    const auto& suggestion = controller_->GetSuggestionAt(index);
    return (suggestion.IsAcceptable() || !suggestion.children.empty()) && !(*suggestion.is_loading);
  }
  void SelectNext(int direction) {
    const int count = controller_->GetLineCount();
    if (!count) return;
    int next = selected_;
    for (int i = 0; i < count; ++i) {
      next = NextPasswordSuggestionIndex(next, count, direction);
      if (Selectable(next)) {
        selected_ = next;
        controller_->SelectSuggestion(next);
        for (NSButton* button in rows_) button.state = button.tag == next ? NSControlStateValueOn : NSControlStateValueOff;
        AxAnnounce(controller_->GetSuggestionAt(next).main_text.value);
        return;
      }
    }
  }
  void Rebuild() {
    // Rebuild only suggestion rows; the page, controller and field editor stay mounted.
    NSArray* children = stack_.arrangedSubviews.copy;
    for (NSView* child in children) { [stack_ removeArrangedSubview:child]; [child removeFromSuperview]; }
    for (CioPasswordAction* action in actions_) action.invoke = nil;
    [actions_ removeAllObjects];
    [rows_ removeAllObjects];
    selected_ = -1;
    Text(base::SysUTF8ToNSString(contents()->GetLastCommittedURL().host()));
    const auto& suggestions = controller_->GetSuggestions();
    for (size_t i = 0; i < suggestions.size(); ++i) {
      const auto& suggestion = suggestions[i];
      if (!Selectable(i)) {
        if (suggestion.type != autofill::SuggestionType::kSeparator)
          Text(base::SysUTF16ToNSString(suggestion.main_text.value));
        continue;
      }
      // Only display the engine's presentation text; never the secret payload.
      NSString* title = base::SysUTF16ToNSString(suggestion.main_text.value);
      if (!suggestion.minor_texts.empty())
        title = [title stringByAppendingFormat:@" · %@", base::SysUTF16ToNSString(suggestion.minor_texts.front().value)];
      auto* button = Button(title, [this, i] {
        auto controller = controller_;
        if (!controller->GetSuggestionAt(i).children.empty()) {
          selected_ = i;
          controller->OpenSubPopup(controller->element_bounds(), controller->GetSuggestionAt(i).children,
                                   autofill::AutoselectFirstSuggestion(true));
          return;
        }
        controller->AcceptSuggestion(i, autofill::AutofillMetrics::SuggestionAcceptedMethod::kMouse);
      });
      button.tag = i;
      [button setButtonType:NSButtonTypePushOnPushOff];
      [button.widthAnchor constraintEqualToAnchor:stack_.widthAnchor].active = YES;
      [rows_ addObject:button];
    }
  }
  base::WeakPtr<autofill::AutofillPopupController> controller_;
  int selected_ = -1;
  NSMutableArray<NSButton*>* rows_ = [[NSMutableArray alloc] init];
  base::WeakPtrFactory<SuggestionsSurface> view_weak_factory_{this};
};

class GenerationSurface final : public PasswordGenerationPopupView, public PasswordSurface {
 public:
  explicit GenerationSurface(base::WeakPtr<PasswordGenerationPopupController> controller)
      : PasswordSurface(controller->GetWebContents()), controller_(controller) {
    Text(base::SysUTF16ToNSString(controller_->SuggestedText()), true);
    Text(base::SysUTF16ToNSString(controller_->HelpText()));
    accept_ = Button(@"使用强密码", [this] { controller_->PasswordAccepted(); });
    reject_ = Button(@"取消", [this] { controller_->PasswordRejected(); });
    // Do not copy the generated password into a plaintext label. The original
    // controller generates, previews, fills and presaves it in its own store.
  }
  bool Show() override {
    if (!Present(&controller_->element_bounds())) { Cancel(); return false; }
    return true;
  }
  void Hide() override { delete this; }
  void Cancel() override {
    CloseNative();
    if (auto controller = controller_) controller->Hide(autofill::SuggestionHidingReason::kTabGone);
    else delete this;
  }
  void UpdateState() override {
    accept_.hidden = controller_->state() != PasswordGenerationPopupController::kOfferGeneration;
    reject_.hidden = accept_.hidden;
    if (!Present(&controller_->element_bounds())) Cancel();
  }
  bool UpdateBoundsAndRedrawPopup() override {
    if (!Present(&controller_->element_bounds())) { Cancel(); return false; }
    return true;
  }
  void ButtonSelectionUpdated() override {
    accept_.state = controller_->accept_button_selected() ? NSControlStateValueOn : NSControlStateValueOff;
    reject_.state = controller_->cancel_button_selected() ? NSControlStateValueOn : NSControlStateValueOff;
  }
  bool IsWidgetActive() const override { return HasFocus(); }
 private:
  base::WeakPtr<PasswordGenerationPopupController> controller_;
  NSButton* accept_;
  NSButton* reject_;
};

class AccountSurface final : public AccountChooserPrompt, public PasswordSurface {
 public:
  AccountSurface(CredentialManagerDialogController* controller, content::WebContents* contents)
      : PasswordSurface(contents, true), controller_(controller) {}
  ~AccountSurface() override { ControllerGone(); }
  void ShowAccountChooser() override {
    Text(base::SysUTF16ToNSString(controller_->GetAccountChooserTitle()), true);
    const auto& forms = controller_->GetLocalForms();
    for (size_t i = 0; i < forms.size(); ++i) {
      Text(base::SysUTF8ToNSString(forms[i]->url.host()));
      Button(base::SysUTF16ToNSString(forms[i]->username_value), [this, i] {
        if (!lease_.Complete(1, CanPresentPasswordUI(contents()), Eligible(contents()))) return;
        // Copy before the controller destroys its chooser/local credentials.
        auto form = *controller_->GetLocalForms()[i];
        auto* controller = controller_.get();
        CloseNative();
        controller->OnChooseCredentials(form, password_manager::CredentialType::CREDENTIAL_TYPE_PASSWORD);
      });
    }
    Button(@"取消", [this] { Cancel(); }).keyEquivalent = @"\e";
    if (!Present()) Cancel();
  }
  void ControllerGone() override { controller_ = nullptr; CloseNative(); }
  void Cancel() override {
    auto* controller = controller_.get();
    controller_ = nullptr;
    CloseNative();
    if (controller) controller->OnCloseDialog();
  }
 private:
  raw_ptr<CredentialManagerDialogController> controller_;
};

class CrossDomainSurface final : public PasswordCrossDomainConfirmationPopupView, public PasswordSurface {
 public:
  CrossDomainSurface(base::WeakPtr<PasswordCrossDomainConfirmationPopupControllerInterface> controller,
                     base::OnceClosure confirm, base::OnceClosure cancel)
      : PasswordSurface(controller->GetWebContents()), controller_(controller),
        confirm_(std::move(confirm)), cancel_(std::move(cancel)) {
    Text(base::SysUTF16ToNSString(controller_->GetTitleText()), true);
    Text(base::SysUTF16ToNSString(controller_->GetBodyText()));
    Button(@"确认填入此网站", [this] {
      if (!lease_.Complete(1, CanPresentPasswordUI(contents()), Eligible(contents()))) return;
      auto confirm = std::move(confirm_);
      CloseNative();
      std::move(confirm).Run();  // Controller hides/deletes the view; no access afterwards.
    });
    Button(@"取消", [this] { Cancel(); });
  }
  void Hide() override { delete this; }
  void Cancel() override {
    CloseNative();
    auto cancel = std::move(cancel_);
    if (cancel) std::move(cancel).Run();
  }
  bool OverlapsWithPictureInPictureWindow() const override { return OverlapsPIP(); }
  base::WeakPtr<PasswordCrossDomainConfirmationPopupView> GetWeakPtr() { return view_weak_factory_.GetWeakPtr(); }
  bool Show() { return Present(&controller_->element_bounds()); }
 private:
  base::WeakPtr<PasswordCrossDomainConfirmationPopupControllerInterface> controller_;
  base::OnceClosure confirm_;
  base::OnceClosure cancel_;
  base::WeakPtrFactory<CrossDomainSurface> view_weak_factory_{this};
};

class BoundAuthenticator;
std::set<BoundAuthenticator*>& Authenticators() {
  static auto* value = new std::set<BoundAuthenticator*>; return *value;
}
// The upstream authenticator still supplies Touch ID/screen-lock authorization.
// The host wrapper only revokes an asynchronous result after its page/frame or
// selected pane changes. It also covers reauth whose suggestion UI is gone.
class BoundAuthenticator final : public device_reauth::DeviceAuthenticator,
                                 public content::WebContentsObserver {
 public:
  BoundAuthenticator(std::unique_ptr<device_reauth::DeviceAuthenticator> authenticator,
                     content::WebContents* contents)
      : WebContentsObserver(contents), authenticator_(std::move(authenticator)) {}
  ~BoundAuthenticator() override { Authenticators().erase(this); }
  bool CanAuthenticateWithBiometrics() override { return authenticator_->CanAuthenticateWithBiometrics(); }
  bool CanAuthenticateWithBiometricOrScreenLock() override {
    return authenticator_->CanAuthenticateWithBiometricOrScreenLock();
  }
  void AuthenticateWithMessage(const std::u16string& message, AuthenticateCallback callback) override {
    primary_ = web_contents()->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    frame_ = web_contents()->GetFocusedFrame()
        ? web_contents()->GetFocusedFrame()->GetWeakDocumentPtr() : primary_;
    lease_ = std::make_unique<PasswordRequestLease>(1);
    Authenticators().insert(this);
    authenticator_->AuthenticateWithMessage(message, base::BindOnce(
        [](base::WeakPtr<BoundAuthenticator> self, AuthenticateCallback completion, bool success) {
          bool admitted = self && self->lease_ && self->lease_->Complete(
              self->primary_.AsRenderFrameHostIfValid() && self->frame_.AsRenderFrameHostIfValid() ? 1 : 0,
              CanPresentPasswordUI(self->web_contents()), Eligible(self->web_contents()));
          if (self) Authenticators().erase(self.get());
          std::move(completion).Run(success && admitted);
        }, weak_factory_.GetWeakPtr(), std::move(callback)));
  }
  void Cancel() override {
    Authenticators().erase(this);
    if (lease_) lease_->Cancel();
    authenticator_->Cancel();  // May synchronously destroy this wrapper.
  }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame() || handle->GetRenderFrameHost() == frame_.AsRenderFrameHostIfValid()) Cancel();
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE) Cancel();
  }
  void WebContentsDestroyed() override { Cancel(); }
 private:
  std::unique_ptr<device_reauth::DeviceAuthenticator> authenticator_;
  content::WeakDocumentPtr primary_;
  content::WeakDocumentPtr frame_;
  std::unique_ptr<PasswordRequestLease> lease_;
  base::WeakPtrFactory<BoundAuthenticator> weak_factory_{this};
};
void CancelAuthenticators(content::WebContents* contents) {
  while (true) {
    auto found = std::find_if(Authenticators().begin(), Authenticators().end(),
        [contents](BoundAuthenticator* authenticator) { return !contents || authenticator->web_contents() == contents; });
    if (found == Authenticators().end()) break;
    (*found)->Cancel();
  }
}
}  // namespace

bool ShowPasswordBubble(content::WebContents* contents, bool user_action) {
  HidePasswordBubble(contents);
  if (!Eligible(contents)) return true;  // Handled; never fall through to Chrome Views.
  auto delegate = PasswordsModelDelegateFromWebContents(contents);
  if (!delegate) return true;
  PasswordSurface* surface = nullptr;
  switch (delegate->GetState()) {
    case password_manager::ui::PENDING_PASSWORD_STATE:
    case password_manager::ui::PENDING_PASSWORD_UPDATE_STATE:
      surface = new SaveSurface(contents, user_action); break;
    case password_manager::ui::SAVE_CONFIRMATION_STATE:
      surface = new ConfirmationSurface(contents); break;
    default: return true;  // Other states are managed via chrome://password-manager/.
  }
  if (!surface->Present()) surface->Cancel();
  return true;
}
void HidePasswordBubble(content::WebContents* contents) {
  auto found = Bubbles().find(contents);
  if (found != Bubbles().end()) found->second->Cancel();
}
void CancelPasswordUI(content::WebContents* contents) {
  CancelAuthenticators(contents);
  // Cancellation can destroy a controller and other surfaces synchronously.
  while (true) {
    auto found = std::find_if(Surfaces().begin(), Surfaces().end(),
        [contents](PasswordSurface* surface) { return surface->contents() == contents; });
    if (found == Surfaces().end()) break;
    (*found)->Cancel();
  }
}
void CancelAllPasswordUI() {
  CancelAuthenticators(nullptr);
  while (!Surfaces().empty()) (*Surfaces().begin())->Cancel();
}
bool PasswordUIHasFocus(content::WebContents* contents) {
  return std::any_of(Surfaces().begin(), Surfaces().end(),
      [contents](PasswordSurface* surface) { return surface->contents() == contents && surface->HasFocus(); });
}
base::WeakPtr<autofill::AutofillPopupView> CreatePasswordSuggestions(
    base::WeakPtr<autofill::AutofillPopupController> controller) {
  if (!controller || !Eligible(controller->GetWebContents())) return nullptr;
  return (new SuggestionsSurface(controller))->GetWeakPtr();
}
PasswordGenerationPopupView* CreatePasswordGeneration(base::WeakPtr<PasswordGenerationPopupController> controller) {
  if (!controller || !Eligible(controller->GetWebContents())) return nullptr;
  return new GenerationSurface(controller);
}
std::unique_ptr<AccountChooserPrompt> CreatePasswordAccountChooser(
    CredentialManagerDialogController* controller, content::WebContents* contents) {
  return std::make_unique<AccountSurface>(controller, contents);
}
base::WeakPtr<PasswordCrossDomainConfirmationPopupView> ShowPasswordCrossDomain(
    base::WeakPtr<PasswordCrossDomainConfirmationPopupControllerInterface> controller,
    base::OnceClosure confirm, base::OnceClosure cancel) {
  if (!controller || !Eligible(controller->GetWebContents())) return nullptr;
  auto* surface = new CrossDomainSurface(controller, std::move(confirm), std::move(cancel));
  auto weak = surface->GetWeakPtr();
  if (!surface->Show()) { delete surface; return nullptr; }
  return weak;
}
std::unique_ptr<device_reauth::DeviceAuthenticator> BindPasswordAuthenticator(
    std::unique_ptr<device_reauth::DeviceAuthenticator> authenticator, content::WebContents* contents) {
  if (!authenticator) return nullptr;
  return std::make_unique<BoundAuthenticator>(std::move(authenticator), contents);
}
bool PasswordIMEComposing(content::WebContents* contents) {
  NSResponder* responder = contents ? contents->GetNativeView().GetNativeNSView().window.firstResponder : nil;
  return [responder conformsToProtocol:@protocol(NSTextInputClient)] &&
      [(id<NSTextInputClient>)responder hasMarkedText];
}
}  // namespace cio
