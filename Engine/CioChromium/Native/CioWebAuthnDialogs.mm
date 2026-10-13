#include "chrome/browser/ui/cio/CioWindowHooks.h"
#include "chrome/browser/ui/cio/CioNativeRuntime.h"

#import <AppKit/AppKit.h>
#include <map>
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "components/constrained_window/constrained_window_views.h"
#include "components/web_modal/single_web_contents_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "ui/base/mojom/ui_base_types.mojom-shared.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"
#include "ui/views/window/dialog_delegate.h"

namespace {
class WebAuthnSheet;
std::map<views::Widget*, WebAuthnSheet*>& Sheets() {
  static base::NoDestructor<std::map<views::Widget*, WebAuthnSheet*>> sheets;
  return *sheets;
}

// Keep Chromium's authenticator UI, security-dialog tracking and request
// callbacks. Only its window parenting changes: Cio's AppKit shell is not a
// NativeWidgetMac, so Chromium cannot use it as a Views child-modal parent.
// WebContentsModalDialogManager still owns modality, navigation and tab lifetime.
class WebAuthnSheet final : public web_modal::SingleWebContentsDialogManager,
                           public views::WidgetObserver,
                           public web_modal::ModalDialogHostObserver {
 public:
  WebAuthnSheet(views::Widget* widget,
               web_modal::SingleWebContentsDialogManagerDelegate* delegate)
      : widget_(widget), delegate_(delegate), dialog_(widget->GetNativeWindow()) {
    widget_->AddObserver(this);
    Sheets()[widget] = this;
  }
  ~WebAuthnSheet() override {
    Detach();
    if (host_) host_->RemoveObserver(this);
    if (widget_) {
      Sheets().erase(widget_);
      widget_->RemoveObserver(this);
    }
  }
  void Show() override {
    if (!host_ || !widget_) return;
    NSWindow* parent = host_->GetHostView().GetNativeNSView().window;
    NSWindow* sheet = dialog_.GetNativeNSWindow();
    if (!parent || !sheet) return;
    constrained_window::UpdateWebContentsModalDialogPosition(widget_, host_);
    // AppKit owns sheet placement and its system animation. Establish the
    // native relationship before notifying Views of visibility/focus.
    if (sheet.sheetParent != parent) {
      Detach();
      [parent beginSheet:sheet completionHandler:nil];
    }
    widget_->Show();
    Focus();
  }
  void Hide() override {
    Detach();
    if (widget_) widget_->Hide();
  }
  void Close() override {
    // WillClose deletes this manager synchronously; do not access it afterward.
    if (widget_) widget_->CloseNow();
  }
  void Focus() override {
    if (!widget_) return;
    if (auto* view = widget_->widget_delegate()->GetInitiallyFocusedView())
      view->RequestFocus();
    [dialog_.GetNativeNSWindow() makeKeyWindow];
  }
  void Pulse() override { NSBeep(); }
  bool IsActive() const override { return dialog_.GetNativeNSWindow().isKeyWindow; }
  gfx::NativeWindow dialog() override { return dialog_; }
  void HostChanged(web_modal::WebContentsModalDialogHost* host) override {
    if (host_ == host) return;
    Hide();
    if (host_) host_->RemoveObserver(this);
    host_ = host;
    if (host_) host_->AddObserver(this);
  }
  void OnPositionRequiresUpdate() override {
    if (host_ && widget_)
      constrained_window::UpdateWebContentsModalDialogPosition(widget_, host_);
  }
  void OnHostDestroying() override {
    host_->RemoveObserver(this);
    host_ = nullptr;
    Close();
  }
  void OnWidgetClosing(views::Widget* widget) override { Finish(widget); }
  void OnWidgetDestroying(views::Widget* widget) override { Finish(widget); }

 private:
  void Detach() {
    NSWindow* sheet = dialog_.GetNativeNSWindow();
    if (sheet.sheetParent)
      [sheet.sheetParent endSheet:sheet returnCode:NSModalResponseCancel];
    [sheet orderOut:nil];
  }
  void Finish(views::Widget* widget) {
    Detach();
    Sheets().erase(widget);
    widget->RemoveObserver(this);
    widget_ = nullptr;
    delegate_->WillClose(dialog_);
  }
  raw_ptr<views::Widget> widget_;
  raw_ptr<web_modal::SingleWebContentsDialogManagerDelegate> delegate_;
  raw_ptr<web_modal::WebContentsModalDialogHost> host_ = nullptr;
  gfx::NativeWindow dialog_;
};
}

namespace cio {
std::unique_ptr<views::Widget> CreateWebAuthnDialog(
    views::WidgetDelegate* view, content::WebContents* contents) {
  if (!IsHostedBrowser()) return nullptr;
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(
      constrained_window::GetTopLevelWebContents(contents));
  CHECK(manager);
  // Native sheet modality is supplied above, rather than a nonexistent Views
  // parent. This changes presentation only, never WebAuthn policy or verification.
  view->SetModalType(ui::mojom::ModalType::kNone);
  auto widget = base::WrapUnique(views::DialogDelegate::CreateDialogWidget(
      view, gfx::NativeWindow(), gfx::NativeView()));
  CHECK_EQ(widget->ownership(), views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  manager->ShowDialogWithManager(widget->GetNativeWindow(),
      std::make_unique<WebAuthnSheet>(widget.get(), manager));
  return widget;
}
bool ShowWebAuthnDialog(views::Widget* widget) {
  auto found = Sheets().find(widget);
  if (found == Sheets().end()) return false;
  found->second->Show();
  return true;
}
}
