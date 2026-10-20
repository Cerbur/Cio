#pragma once

namespace content { class WebContents; }
namespace views { class DialogDelegate; class Widget; }

namespace cio {
// Chromium owns the dialog, identity decisions and lifetime. AppKit supplies
// the native window relationship in a shell with no Views BrowserView.
void PrepareFedCmDialog(views::DialogDelegate* delegate);
void TrackFedCmDialog(views::Widget* widget);
void UpdateFedCmDialogPosition(views::Widget* widget, content::WebContents* contents);
void SetFedCmDialogVisibility(views::Widget* widget,
                             content::WebContents* contents, bool visible);
}
