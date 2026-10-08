// Adapted from Mori, MIT, Copyright (c) 2026 Mori contributors.
// Upstream: FujiwaraChoki/mori-browser @ b5b29c2e29061f9b2009e8cc0b2756c6ad62bb20
// License: ThirdParty/Notices/Mori-MIT.txt. Cio modifications copyright 2026 cerbur.
// Cio BrowserWindow: mostly inert (SwiftUI owns the chrome); window-level
// queries answer against the shared Cio NSWindow.

#include "chrome/browser/ui/cio/CioBrowserWindow.h"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/share/share_attempt.h"
#include "chrome/browser/themes/theme_service.h"
#include "ui/native_theme/native_theme.h"
#include "ui/color/color_provider_manager.h"
#include "ui/color/color_provider_key.h"
#include "components/omnibox/browser/location_bar_model.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/autofill/autofill_bubble_handler.h"
#include "chrome/browser/ui/autofill/save_address_bubble_controller.h"
#include "chrome/browser/ui/autofill/update_address_bubble_controller.h"
#include "chrome/browser/ui/cio/CioWindowHooks.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_bubble_type.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/sharing_message/sharing_dialog_data.h"
#include "components/web_modal/modal_dialog_host.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/gfx/range/range.h"

// AppKit action router (CioRoot.mm); declared locally so
// this window can route web-content key events through the same shortcut
// registry the app-level NSEvent monitor uses, without pulling in the bridge.
@interface CioRoot : NSObject
+ (BOOL)handleShortcutEvent:(NSEvent*)event;
+ (void)toggleBookmarkForURL:(NSString*)url title:(NSString*)title;
+ (void)shareURL:(NSString*)url title:(NSString*)title;
+ (void)showQRCodeForURL:(NSString*)url title:(NSString*)title;
+ (void)translateURL:(NSString*)url;
+ (void)translateText:(NSString*)text;
+ (void)showNativeNotice:(NSString*)message icon:(NSString*)icon;
+ (void)showTabSearch;
+ (void)focusOmnibox;
@end

namespace {

// Cio's chrome shortcuts (⌘S toggle sidebar, ⌘T toggle omnibox, …) belong to
// the SwiftUI registry. Claim them here — in the browser's keyboard pre-handler
// — so they win *before* the focused web page or Chromium's own commands
// (Save Page As on ⌘S, New Tab on ⌘T) can act. This is what makes the
// shortcuts fire reliably while web content has focus, instead of racing the
// app-level NSEvent monitor and Chromium's native accelerators (the
// intermittent "needs two presses" behavior).
bool HandleCioShortcut(const input::NativeWebKeyboardEvent& event) {
  // Only fire on the raw key-down; ignore synthesized char and key-up events.
  if (event.GetType() != input::NativeWebKeyboardEvent::Type::kRawKeyDown) {
    return false;
  }
  NSEvent* ns_event = event.os_event.Get();
  if (!ns_event || ns_event.type != NSEventTypeKeyDown) {
    return false;
  }
  return [CioRoot handleShortcutEvent:ns_event] == YES;
}

NSString* OriginDisclosureLabel(const url::Origin& origin) {
  const std::string serialized_origin = origin.Serialize();
  if (serialized_origin.empty() || serialized_origin == "null") {
    return @"Cio Browser";
  }
  return base::SysUTF8ToNSString(serialized_origin);
}


class CioAutofillBubbleHandler final : public autofill::AutofillBubbleHandler {
 public:
  CioAutofillBubbleHandler() = default;
  ~CioAutofillBubbleHandler() override = default;

  autofill::AutofillBubbleBase* ShowSaveCreditCardBubble(
      content::WebContents* web_contents,
      autofill::SaveCardBubbleController* controller,
      bool is_user_gesture) override {
    Notice(@"Payment autofill bubbles are not exposed in Cio yet.",
           @"creditcard");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowIbanBubble(
      content::WebContents* web_contents,
      autofill::IbanBubbleController* controller,
      bool is_user_gesture,
      autofill::IbanBubbleType bubble_type) override {
    Notice(@"Payment autofill bubbles are not exposed in Cio yet.",
           @"creditcard");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowOfferNotificationBubble(
      content::WebContents* web_contents,
      autofill::OfferNotificationBubbleController* controller,
      bool is_user_gesture) override {
    Notice(@"Autofill offer bubbles are not exposed in Cio yet.", @"tag");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowSaveAutofillAiDataBubble(
      content::WebContents* web_contents,
      autofill::AutofillAiImportDataController* controller) override {
    Notice(@"Autofill AI bubbles are not exposed in Cio yet.", @"sparkles");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowAutofillAiLocalSaveNotification(
      content::WebContents* web_contents,
      autofill::AutofillAiImportDataController* controller) override {
    Notice(@"Autofill AI bubbles are not exposed in Cio yet.", @"sparkles");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowSaveAddressProfileBubble(
      content::WebContents* web_contents,
      std::unique_ptr<autofill::SaveAddressBubbleController> controller,
      bool is_user_gesture) override {
    Notice(@"Address autofill bubbles are not exposed in Cio yet.",
           @"person.text.rectangle");
    return nullptr;
  }

#if BUILDFLAG(ENABLE_DICE_SUPPORT)
  autofill::AutofillBubbleBase* ShowAddressSignInPromo(
      content::WebContents* web_contents,
      const autofill::AutofillProfile& autofill_profile) override {
    Notice(@"Address autofill sign-in is not exposed in Cio yet.",
           @"person.crop.circle.badge.plus");
    return nullptr;
  }
#endif

  autofill::AutofillBubbleBase* ShowUpdateAddressProfileBubble(
      content::WebContents* web_contents,
      std::unique_ptr<autofill::UpdateAddressBubbleController> controller,
      bool is_user_gesture) override {
    Notice(@"Address autofill bubbles are not exposed in Cio yet.",
           @"person.text.rectangle");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowFilledCardInformationBubble(
      content::WebContents* web_contents,
      autofill::FilledCardInformationBubbleController* controller,
      bool is_user_gesture) override {
    Notice(@"Payment autofill bubbles are not exposed in Cio yet.",
           @"creditcard");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowVirtualCardEnrollBubble(
      content::WebContents* web_contents,
      autofill::VirtualCardEnrollBubbleController* controller,
      bool is_user_gesture) override {
    Notice(@"Virtual card enrollment is not exposed in Cio yet.",
           @"creditcard.trianglebadge.exclamationmark");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowVirtualCardEnrollConfirmationBubble(
      content::WebContents* web_contents,
      autofill::VirtualCardEnrollBubbleController* controller) override {
    Notice(@"Virtual card enrollment is not exposed in Cio yet.",
           @"creditcard.trianglebadge.exclamationmark");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowMandatoryReauthBubble(
      content::WebContents* web_contents,
      autofill::MandatoryReauthBubbleController* controller,
      bool is_user_gesture,
      autofill::MandatoryReauthBubbleType bubble_type) override {
    Notice(@"Autofill reauthentication is not exposed in Cio yet.",
           @"lock.shield");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowSaveCardConfirmationBubble(
      content::WebContents* web_contents,
      autofill::SaveCardBubbleController* controller) override {
    Notice(@"Payment autofill bubbles are not exposed in Cio yet.",
           @"creditcard");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowSaveIbanConfirmationBubble(
      content::WebContents* web_contents,
      autofill::IbanBubbleController* controller) override {
    Notice(@"Payment autofill bubbles are not exposed in Cio yet.",
           @"creditcard");
    return nullptr;
  }

  autofill::AutofillBubbleBase* ShowOmniboxAutofillBubble(
      content::WebContents*, autofill::OmniboxAutofillBubbleController*) override { return nullptr; }
  autofill::AutofillBubbleBase* ShowPaymentsChurnedUsersBubble(
      content::WebContents*, autofill::PaymentsChurnedUsersBubbleController*, bool) override { return nullptr; }
 private:
  static void Notice(NSString* message, NSString* icon) {
    [CioRoot showNativeNotice:message icon:icon];
  }
};

}  // namespace

CioBrowserWindow::CioBrowserWindow(Browser* browser)
    : browser_(browser),
      modal_dialog_host_(),
      exclusive_access_context_(browser),
      location_bar_(browser) {
  cio::OnBrowserWindowCreated(browser);
}

// --- CioFindBar --------------------------------------------------------------

FindBarController* CioFindBar::GetFindBarController() const {
  return nullptr;
}

void CioFindBar::SetFindBarController(FindBarController* find_bar_controller) {}

void CioFindBar::Show(bool animate, bool focus) {}

void CioFindBar::Hide(bool animate) {}

void CioFindBar::SetFocusAndSelection() {}

void CioFindBar::ClearResults( const find_in_page::FindNotificationDetails& results) {}

void CioFindBar::StopAnimation() {}

void CioFindBar::MoveWindowIfNecessary() {}

void CioFindBar::SetFindTextAndSelectedRange( const std::u16string& find_text, const gfx::Range& selected_range) {}

std::u16string_view CioFindBar::GetFindText() const {
  return {};
}

gfx::Range CioFindBar::GetSelectedRange() const {
  return {};
}

void CioFindBar::UpdateUIForFindResult( const find_in_page::FindNotificationDetails& result, const std::u16string& find_text) {}

void CioFindBar::AudibleAlert() {}

bool CioFindBar::IsFindBarVisible() const {
  return false;
}

void CioFindBar::RestoreSavedFocus() {}

bool CioFindBar::HasGlobalFindPasteboard() const {
  return false;
}

void CioFindBar::UpdateFindBarForChangedWebContents() {}

bool CioFindBar::CanPopulateFromSelectedText() {
  return false;
}

const FindBarTesting* CioFindBar::GetFindBarTesting() const {
  return nullptr;
}

bool CioFindBar::HasFocus() const {
  return false;
}

void CioFindBar::CloseOverlappingBubbles() {}

views::Widget* CioFindBar::GetHostWidget() {
  return nullptr;
}

// --- CioLocationBar ---------------------------------------------------------

void CioLocationBar::FocusLocation(bool is_user_initiated, bool clear_focus_if_failed) { [CioRoot focusOmnibox]; }

void CioLocationBar::FocusSearch() { [CioRoot focusOmnibox]; }

void CioLocationBar::UpdateFocusBehavior(bool toolbar_visible) {}

void CioLocationBar::UpdateContentSettingsIcons() {}

void CioLocationBar::SaveStateToContents(content::WebContents* contents) {}

void CioLocationBar::Revert() {}

OmniboxView* CioLocationBar::GetOmniboxView() {
  return nullptr;
}

OmniboxPopupView* CioLocationBar::GetOmniboxPopupView() {
  return nullptr;
}

OmniboxController* CioLocationBar::GetOmniboxController() {
  return nullptr;
}

bool CioLocationBar::ShouldCloseOmniboxPopup(ui::MouseEvent* event) {
  return false;
}

content::WebContents* CioLocationBar::GetWebContents() {
  return browser_ ? browser_->tab_strip_model()->GetActiveWebContents() : nullptr;
}

LocationBarModel* CioLocationBar::GetLocationBarModel() {
  return nullptr;  // Cio owns the address field and its presentation model.
}

std::optional<bubble_anchor_util::AnchorConfiguration> CioLocationBar::GetChipAnchor() {
  return {};
}

ChipController* CioLocationBar::GetChipController() {
  return nullptr;
}

void CioLocationBar::OnChanged() {}

void CioLocationBar::UpdateWithoutTabRestore() {}

ui::TrackedElement* CioLocationBar::GetAnchorOrNull() {
  return nullptr;
}

Browser* CioLocationBar::GetBrowser() {
  return browser_;
}

Profile* CioLocationBar::GetProfile() {
  return browser_ ? browser_->GetProfile() : nullptr;
}

bool CioLocationBar::IsInitialized() const {
  return browser_ != nullptr;
}

bool CioLocationBar::IsVisible() const {
  return false;
}

bool CioLocationBar::IsDrawn() const {
  return false;
}

bool CioLocationBar::IsFullscreen() const {
  return false;
}

bool CioLocationBar::IsEditingOrEmpty() const {
  return false;
}

void CioLocationBar::InvalidateLayout() {}

gfx::Rect CioLocationBar::Bounds() const {
  return {};
}

gfx::Rect CioLocationBar::BoundsInScreen() const {
  return {};
}

gfx::Size CioLocationBar::MinimumSize() const {
  return {};
}

gfx::Size CioLocationBar::PreferredSize() const {
  return {};
}

void CioLocationBar::Update(content::WebContents* contents) {}

void CioLocationBar::ResetTabState(content::WebContents* contents) {}

bool CioLocationBar::HasSecurityStateChanged() {
  return false;
}

LocationBarTesting* CioLocationBar::GetLocationBarForTesting() {
  return nullptr;
}

// --- CioExclusiveAccessContext ---------------------------------------------

CioExclusiveAccessContext::CioExclusiveAccessContext(Browser* browser)
    : browser_(browser) {}

CioExclusiveAccessContext::~CioExclusiveAccessContext() {
  HideFullscreenDisclosure(ExclusiveAccessBubbleHideReason::kInterrupted);
}

Profile* CioExclusiveAccessContext::GetProfile() {
  return browser_->GetProfile();
}

bool CioExclusiveAccessContext::IsFullscreen() const {
  NSWindow* window = cio::CioMainWindow();
  return window && (window.styleMask & NSWindowStyleMaskFullScreen);
}

void CioExclusiveAccessContext::EnterFullscreen(
    const url::Origin& origin,
    ExclusiveAccessBubbleType bubble_type,
    FullscreenTabParams fullscreen_tab_params) {
  NSWindow* window = cio::CioMainWindow();
  if (window && !(window.styleMask & NSWindowStyleMaskFullScreen)) {
    [window toggleFullScreen:nil];
  }
  ShowFullscreenDisclosure(origin);
}

void CioExclusiveAccessContext::ExitFullscreen() {
  HideFullscreenDisclosure(ExclusiveAccessBubbleHideReason::kInterrupted);
  NSWindow* window = cio::CioMainWindow();
  if (window && (window.styleMask & NSWindowStyleMaskFullScreen)) {
    [window toggleFullScreen:nil];
  }
}

void CioExclusiveAccessContext::UpdateExclusiveAccessBubble(
    const ExclusiveAccessBubbleParams& params,
    ExclusiveAccessBubbleHideCallback first_hide_callback) {
  const bool should_close_bubble =
      !params.has_download &&
      params.type == EXCLUSIVE_ACCESS_BUBBLE_TYPE_NONE;
  if (should_close_bubble) {
    if (first_hide_callback) {
      std::move(first_hide_callback)
          .Run(ExclusiveAccessBubbleHideReason::kNotShown);
    }
    HideFullscreenDisclosure(ExclusiveAccessBubbleHideReason::kInterrupted);
    return;
  }
  ShowFullscreenDisclosure(params.origin, std::move(first_hide_callback));
}

bool CioExclusiveAccessContext::IsExclusiveAccessBubbleDisplayed() const {
  return exclusive_access_bubble_visible_;
}

void CioExclusiveAccessContext::OnExclusiveAccessUserInput() {
  NSPanel* panel = (__bridge NSPanel*)fullscreen_disclosure_.get();
  if (panel) {
    [panel orderFront:nil];
  }
}

content::WebContents* CioExclusiveAccessContext::GetWebContentsForExclusiveAccess() {
  return browser_->tab_strip_model()->GetActiveWebContents();
}

bool CioExclusiveAccessContext::CanUserEnterFullscreen() const {
  return true;
}

bool CioExclusiveAccessContext::CanUserExitFullscreen() const {
  return true;
}

void CioExclusiveAccessContext::ShowFullscreenDisclosure(
    const url::Origin& origin,
    ExclusiveAccessBubbleHideCallback first_hide_callback) {
  NSWindow* parent = cio::CioMainWindow();
  if (!parent) {
    if (first_hide_callback) {
      std::move(first_hide_callback)
          .Run(ExclusiveAccessBubbleHideReason::kNotShown);
    }
    return;
  }

  HideFullscreenDisclosure(ExclusiveAccessBubbleHideReason::kInterrupted);

  NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 72)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskNonactivatingPanel
      backing:NSBackingStoreBuffered defer:NO];
  panel.title = @"全屏浏览";
  panel.ignoresMouseEvents = YES;
  panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
  NSTextField* label = [NSTextField labelWithString:
      [NSString stringWithFormat:@"%@ · 按 Esc 退出全屏", OriginDisclosureLabel(origin)]];
  label.frame = NSInsetRect(panel.contentView.bounds, 16, 16);
  label.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [panel.contentView addSubview:label];
  [panel center];
  [parent addChildWindow:panel ordered:NSWindowAbove];
  [panel orderFront:nil];

  fullscreen_disclosure_ = (__bridge_retained void*)panel;
  fullscreen_disclosure_hide_callback_ = std::move(first_hide_callback);
  exclusive_access_bubble_visible_ = true;
}

void CioExclusiveAccessContext::HideFullscreenDisclosure(
    ExclusiveAccessBubbleHideReason reason) {
  NSPanel* panel = (__bridge_transfer NSPanel*)fullscreen_disclosure_.get();
  fullscreen_disclosure_ = nullptr;
  exclusive_access_bubble_visible_ = false;

  if (panel) {
    [panel.parentWindow removeChildWindow:panel];
    [panel orderOut:nil];
    [panel close];
  }

  if (fullscreen_disclosure_hide_callback_) {
    std::move(fullscreen_disclosure_hide_callback_).Run(reason);
  }
}

CioBrowserWindow::~CioBrowserWindow() {
  // Match Chromium's window lifetime contract: disconnect window-feature
  // observers before their dependencies and BrowserWindow are destroyed.
  browser_->GetFeatures().TearDownPreBrowserWindowDestruction();
  cio::OnBrowserWindowDestroyed(browser_);
}

CioModalDialogHost::CioModalDialogHost() = default;
bool CioLocationBar::IsFocusWithin() const { return cio::CioMainWindow().isKeyWindow; }
bool CioLocationBar::IsMouseHovered() const { return false; }

// --- CioModalDialogHost ----------------------------------------------------

CioModalDialogHost::~CioModalDialogHost() {
  for (auto& observer : observers_) {
    observer.OnHostDestroying();
  }
}

gfx::NativeView CioModalDialogHost::GetHostView() const {
  return gfx::NativeView(cio::CioMainWindow().contentView);
}

gfx::Point CioModalDialogHost::GetDialogPosition(const gfx::Size& size) {
  NSView* content = cio::CioMainWindow().contentView;
  const int width = content ? NSWidth(content.bounds) : 1280;
  return gfx::Point(std::max(0, (width - size.width()) / 2), 64);
}

gfx::Size CioModalDialogHost::GetMaximumDialogSize() {
  NSView* content = cio::CioMainWindow().contentView;
  if (!content) {
    return gfx::Size(1200, 760);
  }
  return gfx::Size(NSWidth(content.bounds), NSHeight(content.bounds));
}

void CioModalDialogHost::AddObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.AddObserver(observer);
}

void CioModalDialogHost::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.RemoveObserver(observer);
}

bool CioBrowserWindow::IsMaximized() const {
  return false;
}

bool CioBrowserWindow::IsMinimized() const {
  return cio::CioMainWindow().isMiniaturized;
}

bool CioBrowserWindow::IsFullscreen() const {
  return (cio::CioMainWindow().styleMask & NSWindowStyleMaskFullScreen) != 0;
}

void CioBrowserWindow::Hide() {}

void CioBrowserWindow::ShowInactive() {}

void CioBrowserWindow::Deactivate() {}

void CioBrowserWindow::Maximize() {}

void CioBrowserWindow::Minimize() {}

void CioBrowserWindow::Restore() {}

void CioBrowserWindow::FlashFrame(bool flash) {}

ui::ZOrderLevel CioBrowserWindow::GetZOrderLevel() const {
  return ui::ZOrderLevel::kNormal;
}

void CioBrowserWindow::SetZOrderLevel(ui::ZOrderLevel order) {}

bool CioBrowserWindow::IsOnCurrentWorkspace() const {
  return cio::CioMainWindow().isOnActiveSpace;
}

bool CioBrowserWindow::IsVisibleOnScreen() const {
  return IsVisible();
}

void CioBrowserWindow::SetTopControlsShownRatio(content::WebContents* web_contents, float ratio) {}

bool CioBrowserWindow::DoBrowserControlsShrinkRendererSize( const content::WebContents* contents) const {
  return false;
}

ui::NativeTheme* CioBrowserWindow::GetNativeTheme() {
  return ui::NativeTheme::GetInstanceForNativeUi();
}

const ui::ThemeProvider* CioBrowserWindow::GetThemeProvider() const {
  return &ThemeService::GetThemeProviderForProfile(browser_->GetProfile());
}

const ui::ColorProvider* CioBrowserWindow::GetColorProvider() const {
  auto* contents = browser_->tab_strip_model()->GetActiveWebContents();
  if (contents) return &contents->GetColorProvider();
  ui::ColorProviderKey key;
  key.color_mode = (ui::NativeTheme::GetInstanceForNativeUi()->preferred_color_scheme() == ui::NativeTheme::PreferredColorScheme::kDark)
      ? ui::ColorProviderKey::ColorMode::kDark : ui::ColorProviderKey::ColorMode::kLight;
  return ui::ColorProviderManager::Get().GetColorProviderFor(key);
}

int CioBrowserWindow::GetTopControlsHeight() const {
  return {};
}

void CioBrowserWindow::SetTopControlsGestureScrollInProgress(bool in_progress) {}

std::vector<StatusBubble*> CioBrowserWindow::GetStatusBubbles() {
  return {};
}

void CioBrowserWindow::UpdateTitleBar() {}

void CioBrowserWindow::BookmarkBarStateChanged( BookmarkBar::AnimateChangeType change_type) {}

void CioBrowserWindow::TemporarilyShowBookmarkBar(base::TimeDelta duration) {}

void CioBrowserWindow::UpdateDevTools(content::WebContents* inspected_web_contents) { cio::RefreshDevTools(); }

bool CioBrowserWindow::CanDockDevTools() const {
  return true;
}

void CioBrowserWindow::UpdateLoadingAnimations(bool is_visible) {}

void CioBrowserWindow::SetStarredState(bool is_starred) {}

bool CioBrowserWindow::IsTabModalPopupDeprecated() const {
  return false;
}

void CioBrowserWindow::SetIsTabModalPopupDeprecated( bool is_tab_modal_popup_deprecated) {}

void CioBrowserWindow::OnActiveTabChanged(content::WebContents* old_contents, content::WebContents* new_contents, int index, int reason) {}

void CioBrowserWindow::OnTabDetached(content::WebContents* contents, bool was_active) {}

void CioBrowserWindow::ZoomChangedForActiveTab(bool can_show_bubble) {}

bool CioBrowserWindow::ShouldHideUIForFullscreen() const {
  return false;
}

bool CioBrowserWindow::IsFullscreenBubbleVisible() const {
  return false;
}

bool CioBrowserWindow::IsForceFullscreen() const {
  return false;
}

void CioBrowserWindow::SetForceFullscreen(bool force_fullscreen) {}

gfx::Size CioBrowserWindow::GetContentsSize() const {
  return {};
}

void CioBrowserWindow::SetContentsSize(const gfx::Size& size) {}

void CioBrowserWindow::UpdatePageActionIcon(PageActionIconType type) {}

autofill::AutofillBubbleHandler* CioBrowserWindow::GetAutofillBubbleHandler() {
  static CioAutofillBubbleHandler* handler = new CioAutofillBubbleHandler();
  return handler;
}

void CioBrowserWindow::ExecutePageActionIconForTesting(PageActionIconType type) {}

LocationBar* CioBrowserWindow::GetLocationBar() const {
  return const_cast<CioLocationBar*>(&location_bar_);
}

void CioBrowserWindow::SetFocusToLocationBar(bool is_user_initiated) {
  [CioRoot focusOmnibox];
}

void CioBrowserWindow::UpdateReloadStopState(bool is_loading, bool force) {}

void CioBrowserWindow::UpdateToolbar(content::WebContents* contents) {}

bool CioBrowserWindow::UpdateToolbarSecurityState() {
  return false;
}

void CioBrowserWindow::UpdateCustomTabBarVisibility(bool visible, bool animate) {}

void CioBrowserWindow::SetDevToolsScrimVisibility(bool visible) {}

void CioBrowserWindow::ResetToolbarTabState(content::WebContents* contents) {}

void CioBrowserWindow::FocusToolbar() {}

void CioBrowserWindow::ToolbarSizeChanged(bool is_animating) {}

void CioBrowserWindow::TabDraggingStatusChanged(bool is_dragging) {}

void CioBrowserWindow::LinkOpeningFromGesture(WindowOpenDisposition disposition) {}

void CioBrowserWindow::FocusAppMenu() {}

void CioBrowserWindow::FocusBookmarksToolbar() {}

void CioBrowserWindow::FocusInactivePopupForAccessibility() {}

void CioBrowserWindow::RotatePaneFocus(bool forwards) {}

void CioBrowserWindow::FocusWebContentsPane() {
  // Chromium's focus restoration must respect the shell's active pane and
  // native editor ownership, just like explicit BrowserBridge focus requests.
  if (!cio::CanFocusBrowser(browser_)) return;
  if (content::WebContents* contents =
          browser_->tab_strip_model()->GetActiveWebContents()) {
    contents->Focus();
  }
}

bool CioBrowserWindow::IsBookmarkBarVisible() const {
  return false;
}

bool CioBrowserWindow::IsBookmarkBarAnimating() const {
  return false;
}

bool CioBrowserWindow::IsTabStripEditable() const {
  return true;
}

void CioBrowserWindow::DisableTabStripEditingForTesting() {}

bool CioBrowserWindow::IsToolbarVisible() const {
  return false;
}

bool CioBrowserWindow::IsToolbarShowing() const {
  return false;
}

bool CioBrowserWindow::IsLocationBarVisible() const {
  return false;
}

SharingDialog* CioBrowserWindow::ShowSharingDialog(content::WebContents* contents, SharingDialogData data) {
  content::WebContents* target =
      contents ? contents : browser_->tab_strip_model()->GetActiveWebContents();
  if (target) {
    [CioRoot shareURL:base::SysUTF8ToNSString(target->GetVisibleURL().spec())
                 title:base::SysUTF16ToNSString(target->GetTitle())];
  }
  return nullptr;
}

void CioBrowserWindow::ShowUpdateChromeDialog() {}

void CioBrowserWindow::ShowIntentPickerBubble( std::vector<apps::IntentPickerAppInfo> app_info, bool show_stay_in_chrome, bool show_remember_selection, apps::IntentPickerBubbleType bubble_type, const std::optional<url::Origin>& initiating_origin, IntentPickerResponse callback) {
  if (app_info.empty()) {
    std::move(callback).Run(std::string(), apps::PickerEntryType::kUnknown,
                            apps::IntentPickerCloseReason::STAY_IN_CHROME,
                            false);
    return;
  }

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Open this link in another app?";
  alert.informativeText = @"Choose an app or keep browsing in Cio.";
  alert.alertStyle = NSAlertStyleInformational;
  for (const auto& app : app_info) {
    [alert addButtonWithTitle:base::SysUTF8ToNSString(app.display_name)];
  }
  [alert addButtonWithTitle:@"Stay in Cio"];

  NSModalResponse response = [alert runModal];
  NSInteger selected = response - NSAlertFirstButtonReturn;
  if (selected >= 0 && selected < static_cast<NSInteger>(app_info.size())) {
    const auto& app = app_info[static_cast<size_t>(selected)];
    std::move(callback).Run(app.launch_name, app.type,
                            apps::IntentPickerCloseReason::OPEN_APP,
                            false);
    return;
  }
  std::move(callback).Run(std::string(), apps::PickerEntryType::kUnknown,
                          apps::IntentPickerCloseReason::STAY_IN_CHROME,
                          false);
}

void CioBrowserWindow::ShowBookmarkBubble(const GURL& url, bool already_bookmarked) {
  const std::string spec = url.is_valid() ? url.spec() : std::string();
  NSString* title = @"";
  if (content::WebContents* contents =
          browser_->tab_strip_model()->GetActiveWebContents()) {
    title = base::SysUTF16ToNSString(contents->GetTitle());
  }
  [CioRoot toggleBookmarkForURL:base::SysUTF8ToNSString(spec) title:title];
}

sharing_hub::ScreenshotCapturedBubble* CioBrowserWindow::ShowScreenshotCapturedBubble( content::WebContents* contents, const gfx::Image& image) {
  [CioRoot showNativeNotice:@"Screenshot captured."
                        icon:@"camera.viewfinder"];
  return nullptr;
}

qrcode_generator::QRCodeGeneratorBubbleView* CioBrowserWindow::ShowQRCodeGeneratorBubble(content::WebContents* contents, const GURL& url, bool show_back_button) {
  NSString* title = contents ? base::SysUTF16ToNSString(contents->GetTitle()) : @"";
  const std::string spec = url.is_valid()
                               ? url.spec()
                               : (contents ? contents->GetVisibleURL().spec()
                                           : std::string());
  [CioRoot showQRCodeForURL:base::SysUTF8ToNSString(spec) title:title];
  return nullptr;
}

send_tab_to_self::SendTabToSelfBubbleView* CioBrowserWindow::ShowSendTabToSelfDevicePickerBubble(content::WebContents* contents) {
  [CioRoot showNativeNotice:@"Send to device is not exposed in Cio yet."
                        icon:@"paperplane"];
  return nullptr;
}

send_tab_to_self::SendTabToSelfBubbleView* CioBrowserWindow::ShowSendTabToSelfPromoBubble(content::WebContents* contents, bool show_signin_button) {
  [CioRoot showNativeNotice:@"Send to device is not exposed in Cio yet."
                        icon:@"paperplane"];
  return nullptr;
}

sharing_hub::SharingHubBubbleView* CioBrowserWindow::ShowSharingHubBubble( share::ShareAttempt attempt) {
  if (content::WebContents* contents =
          browser_->tab_strip_model()->GetActiveWebContents()) {
    [CioRoot shareURL:base::SysUTF8ToNSString(contents->GetVisibleURL().spec())
                 title:base::SysUTF16ToNSString(contents->GetTitle())];
  }
  return nullptr;
}

ShowTranslateBubbleResult CioBrowserWindow::ShowTranslateBubble( content::WebContents* contents, translate::TranslateStep step, const std::string& source_language, const std::string& target_language, translate::TranslateErrors error_type, bool is_user_gesture) {
  if (contents) {
    [CioRoot translateURL:base::SysUTF8ToNSString(contents->GetVisibleURL().spec())];
  }
  return {};
}

void CioBrowserWindow::StartPartialTranslate(const std::string& source_language, const std::string& target_language, const std::u16string& text_selection) {
  [CioRoot translateText:base::SysUTF16ToNSString(text_selection)];
}

DownloadBubbleUIController* CioBrowserWindow::GetDownloadBubbleUIController() {
  return nullptr;
}

void CioBrowserWindow::ConfirmBrowserCloseWithPendingDownloads( int download_count, UnloadController::DownloadCloseType dialog_type, base::OnceCallback<void(bool)> callback) {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = download_count == 1
                          ? @"A download is still in progress."
                          : [NSString stringWithFormat:@"%d downloads are still in progress.",
                                                       download_count];
  alert.informativeText = @"Closing Cio now will cancel unfinished downloads.";
  alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:@"Close Anyway"];
  [alert addButtonWithTitle:@"Keep Browsing"];
  NSModalResponse response = [alert runModal];
  std::move(callback).Run(response == NSAlertFirstButtonReturn);
}

void CioBrowserWindow::ShowAppMenu() {
  NSMenu* appMenu = [[NSApp.mainMenu itemAtIndex:0] submenu];
  if (!appMenu) {
    return;
  }
  NSWindow* window = cio::CioMainWindow();
  NSPoint point = window ? NSMakePoint(NSMidX(window.frame), NSMaxY(window.frame) - 40)
                         : NSMakePoint(24, 24);
  [appMenu popUpMenuPositioningItem:nil atLocation:point inView:nil];
}

void CioBrowserWindow::PreHandleDragUpdate(const content::DropData& drop_data, const gfx::PointF& point) {}

void CioBrowserWindow::PreHandleDragExit() {}

void CioBrowserWindow::HandleDragEnded() {}

content::KeyboardEventProcessingResult CioBrowserWindow::PreHandleKeyboardEvent( const input::NativeWebKeyboardEvent& event) {
  if (HandleCioShortcut(event)) {
    return content::KeyboardEventProcessingResult::HANDLED;
  }
  return content::KeyboardEventProcessingResult::NOT_HANDLED;
}

bool CioBrowserWindow::HandleKeyboardEvent( const input::NativeWebKeyboardEvent& event) {
  return false;
}

std::unique_ptr<FindBar> CioBrowserWindow::CreateFindBar() {
  return std::make_unique<CioFindBar>();
}

web_modal::WebContentsModalDialogHost*
CioBrowserWindow::GetWebContentsModalDialogHost() {
  return &modal_dialog_host_;
}

web_modal::WebContentsModalDialogHost*
CioBrowserWindow::GetWebContentsModalDialogHostFor(
    content::WebContents* web_contents) {
  return &modal_dialog_host_;
}

void CioBrowserWindow::ShowAvatarBubbleFromAvatarButton(bool is_source_accelerator) {
  [CioRoot showNativeNotice:@"Profiles are not exposed in Cio yet."
                        icon:@"person.crop.circle"];
}

void CioBrowserWindow::MaybeShowProfileSwitchIPH() {}

void CioBrowserWindow::MaybeShowSupervisedUserProfileSignInIPH() {}

void CioBrowserWindow::ShowHatsDialog( const std::string& site_id, const std::optional<std::string>& hats_histogram_name, const std::optional<uint64_t> hats_survey_ukm_id, base::OnceClosure success_callback, base::OnceClosure failure_callback, const SurveyBitsData& product_specific_bits_data, const SurveyStringData& product_specific_string_data) {}

ExclusiveAccessContext* CioBrowserWindow::GetExclusiveAccessContext() {
  return &exclusive_access_context_;
}

std::string CioBrowserWindow::GetWorkspace() const {
  return {};
}

bool CioBrowserWindow::IsVisibleOnAllWorkspaces() const {
  return false;
}

void CioBrowserWindow::ShowEmojiPanel() {
  [NSApp orderFrontCharacterPalette:nil];
}

std::unique_ptr<content::EyeDropper> CioBrowserWindow::OpenEyeDropper( content::RenderFrameHost* frame, content::EyeDropperListener* listener) {
  [CioRoot showNativeNotice:@"Eye dropper is not exposed in Cio yet."
                        icon:@"eyedropper"];
  return {};
}

void CioBrowserWindow::ShowCaretBrowsingDialog() {
  [CioRoot showNativeNotice:@"Caret browsing is not exposed in Cio yet."
                        icon:@"text.cursor"];
}

void CioBrowserWindow::CreateTabSearchBubble() {
  [CioRoot showTabSearch];
}

void CioBrowserWindow::CloseTabSearchBubble() {}

void CioBrowserWindow::ShowIncognitoClearBrowsingDataDialog() {
  [CioRoot showNativeNotice:@"Private browsing is not exposed in Cio yet."
                        icon:@"eye.slash"];
}

void CioBrowserWindow::ShowIncognitoHistoryDisclaimerDialog() {
  [CioRoot showNativeNotice:@"Private browsing is not exposed in Cio yet."
                        icon:@"eye.slash"];
}

bool CioBrowserWindow::IsUnframedModeEnabled() const {
  return false;
}

bool CioBrowserWindow::GetCanResize() {
  return false;
}

ui::mojom::WindowShowState CioBrowserWindow::GetWindowShowState() const {
  return {};
}

void CioBrowserWindow::ShowChromeLabs() {
  [CioRoot showNativeNotice:@"Chrome Labs is not exposed in Cio."
                        icon:@"flask"];
}

BrowserView* CioBrowserWindow::AsBrowserView() {
  return nullptr;
}

void CioBrowserWindow::DeleteBrowserWindow() {
  delete this;
}

// --- Real implementations against the shared Cio window -------------------

namespace {
NSWindow* CioWindow() {
  return cio::CioMainWindow();
}
}  // namespace

void CioBrowserWindow::Show() {
  cio::EnsureCioUIStarted(browser_);
}

void CioBrowserWindow::Close() {
  // OnWindowClosing owns beforeunload, tab closure and deferred Browser
  // destruction. It can re-enter Close through TabStripEmpty. Never access
  // this window after that call or delete Browser synchronously here.
  UnloadController::From(browser_)->OnWindowClosing();
}

bool CioBrowserWindow::IsActive() const {
  return CioWindow().isKeyWindow && cio::CanFocusBrowser(browser_);
}

void CioBrowserWindow::Activate() {
  if (cio::CanFocusBrowser(browser_)) [CioWindow() makeKeyAndOrderFront:nil];
}

gfx::NativeWindow CioBrowserWindow::GetNativeWindow() const {
  return gfx::NativeWindow(CioWindow());
}

gfx::Rect CioBrowserWindow::GetBounds() const {
  NSWindow* window = CioWindow();
  if (!window) {
    return gfx::Rect(0, 0, 1280, 820);
  }
  NSRect f = window.frame;
  NSScreen* screen = window.screen ?: NSScreen.screens.firstObject;
  const CGFloat flipped_y = NSMaxY(screen.frame) - NSMaxY(f);
  return gfx::Rect(NSMinX(f), flipped_y, NSWidth(f), NSHeight(f));
}

gfx::Rect CioBrowserWindow::GetRestoredBounds() const {
  return GetBounds();
}

ui::mojom::WindowShowState CioBrowserWindow::GetRestoredState() const {
  return ui::mojom::WindowShowState::kNormal;
}

bool CioBrowserWindow::IsVisible() const {
  return CioWindow().isVisible;
}

void CioBrowserWindow::SetBounds(const gfx::Rect& bounds) {}
