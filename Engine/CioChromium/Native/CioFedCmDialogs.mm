#include "chrome/browser/ui/cio/CioFedCmDialogs.h"

#import <AppKit/AppKit.h>
#include "content/public/browser/web_contents.h"
#include "ui/base/mojom/ui_base_types.mojom-shared.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/widget/root_view.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"
#include "ui/views/window/dialog_delegate.h"

namespace {
void Detach(views::Widget* widget) {
  NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
  [window.parentWindow removeChildWindow:window];
}

// The FedCM owner destroys its client-owned widget on navigation, tab detach,
// dismissal and shutdown. Remove AppKit's relationship before that teardown.
class FedCmWindowAttachment final : public views::WidgetObserver {
 public:
  explicit FedCmWindowAttachment(views::Widget* widget) {
    widget->AddObserver(this);
  }
  void OnWidgetClosing(views::Widget* widget) override { Detach(widget); }
  void OnWidgetDestroying(views::Widget* widget) override {
    Detach(widget);
    widget->RemoveObserver(this);
    delete this;
  }
};
}

namespace cio {
void PrepareFedCmDialog(views::DialogDelegate* delegate) {
  if (auto* bubble = delegate->AsBubbleDialogDelegate()) {
    // The original content computes its bounds from WebContents. No synthetic
    // Views anchor or NativeWidgetMac parent is needed for its native window.
    bubble->set_has_parent(false);
  } else {
    // FedCM still suppresses page input for its modal flow. Native kChild
    // modality would require a Views parent that Cio deliberately does not own.
    delegate->SetModalType(ui::mojom::ModalType::kNone);
  }
}

void TrackFedCmDialog(views::Widget* widget) {
  new FedCmWindowAttachment(widget);
}

void UpdateFedCmDialogPosition(views::Widget* widget, content::WebContents* contents) {
  if (!widget || !contents) return;
  if (auto* bubble = widget->widget_delegate()->AsBubbleDialogDelegate()) {
    // Retain Chromium's bubble width, margins, RTL and viewport fitting.
    bubble->SizeToContents();
    return;
  }
  const gfx::Rect page = contents->GetViewBounds();
  const gfx::Size size = widget->GetRootView()->GetPreferredSize({});
  gfx::Rect bounds(page.CenterPoint().x() - size.width() / 2,
                   page.CenterPoint().y() - size.height() / 2,
                   size.width(), size.height());
  bounds.AdjustToFit(page);
  widget->SetBounds(bounds);
}

void SetFedCmDialogVisibility(views::Widget* widget,
                             content::WebContents* contents, bool visible) {
  if (!widget) return;
  NSWindow* parent = contents
      ? contents->GetTopLevelNativeWindow().GetNativeNSWindow() : nil;
  NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
  if (!visible || !parent || parent.isMiniaturized) {
    Detach(widget);
    widget->Hide();
    return;
  }
  UpdateFedCmDialogPosition(widget, contents);
  if (window.parentWindow != parent) {
    Detach(widget);
    [parent addChildWindow:window ordered:NSWindowAbove];
  }
  if (!widget->IsVisible()) {
    // A passive account prompt must not activate a background Cio window.
    if (parent.isKeyWindow || window.isKeyWindow) widget->Show();
    else widget->ShowInactive();
  }
}
}
