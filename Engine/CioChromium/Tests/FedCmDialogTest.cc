// The factory body is extracted from the pinned engine, not copied here.
#include <cassert>
#include <cstdio>
#include <memory>
#include <optional>
#include <utility>

#define CHECK(value) assert(value)
#define IS_MAC 1
#define BUILDFLAG(flag) flag
namespace gfx { using NativeWindow = void*; using NativeView = void*; }
namespace ui::mojom { enum class ModalType { kNone, kChild }; }
namespace base {
template <class T> std::unique_ptr<T> WrapUnique(T* ptr) {
  return std::unique_ptr<T>(ptr);
}
}
namespace views {
struct View { virtual ~View() = default; };
template <class T> T* AsViewClass(View* view) { return static_cast<T*>(view); }
struct BubbleDialogDelegate;
struct DialogDelegate;
struct Widget {
  struct InitParams { enum Ownership { CLIENT_OWNS_WIDGET }; };
  static inline Widget* host = nullptr;
  static Widget* GetWidgetForNativeWindow(gfx::NativeWindow) { return host; }
  void* GetNativeView() { assert(this == host); return this; }
};
struct WidgetDelegate {
  virtual ~WidgetDelegate() = default;
  virtual BubbleDialogDelegate* AsBubbleDialogDelegate() { return nullptr; }
  virtual DialogDelegate* AsDialogDelegate() { return nullptr; }
};
struct DialogDelegate : WidgetDelegate {
  bool child_modal = true;
  void SetModalType(ui::mojom::ModalType type) { child_modal = type == ui::mojom::ModalType::kChild; }
  DialogDelegate* AsDialogDelegate() override { return this; }
  static Widget* CreateDialogWidget(DialogDelegate* delegate, gfx::NativeWindow, void* parent) {
    assert(!delegate->child_modal || parent);
    return new Widget;
  }
};
struct BubbleDialogDelegate : DialogDelegate {
  bool has_parent = true;
  View* anchor = nullptr;
  void set_has_parent(bool value) { has_parent = value; }
  BubbleDialogDelegate* AsBubbleDialogDelegate() override { return this; }
  static Widget* CreateBubbleDeprecated(BubbleDialogDelegate* delegate, Widget::InitParams::Ownership) {
    // CreateBubbleWidget's actual failing invariant: no Views anchor/parent.
    assert(delegate->anchor || !delegate->has_parent);
    return new Widget;
  }
};
}
namespace content {
struct WebContents {
  gfx::NativeWindow GetTopLevelNativeWindow() { return this; }
  int IgnoreInputEvents(std::nullopt_t) { return 1; }
};
}
namespace cio {
bool hosted = false;
bool IsHostedBrowser() { return hosted; }
int attachments = 0;
#include "PrepareFedCmDialog.inc"
void TrackFedCmDialog(views::Widget*) { ++attachments; }
bool visible = false;
int positions = 0;
void UpdateFedCmDialogPosition(views::Widget*, content::WebContents*) { ++positions; }
void SetFedCmDialogVisibility(views::Widget*, content::WebContents*, bool requested) { visible = requested; }
}
namespace tabs {
struct TabDialogManager {
  struct Params { bool disable_input = true; };
  int calls = 0;
  void ShowDialog(views::Widget*, std::unique_ptr<Params>) { ++calls; }
  void UpdateModalDialogBounds() { ++calls; }
  void UpdateDialogVisibility(bool) { ++calls; }
  bool IsDialogManaged(views::Widget*) { ++calls; return true; }
};
struct TabFeatures {
  TabDialogManager manager;
  TabDialogManager* tab_dialog_manager() { return &manager; }
};
struct TabInterface {
  bool active = true;
  TabFeatures features;
  bool IsActivated() { return active; }
  TabFeatures* GetTabFeatures() { return &features; }
};
}
namespace extensions {
struct SecurityDialogTracker {
  static SecurityDialogTracker* GetInstance() { static SecurityDialogTracker tracker; return &tracker; }
  int tracked = 0;
  void AddSecurityDialog(views::Widget*) { ++tracked; }
};
}
struct ScopedPictureInPictureOcclusionObservation {
  explicit ScopedPictureInPictureOcclusionObservation(void*) {}
  void Observe(views::Widget*) {}
};
struct InputProtector {
  bool visible = true;
  void VisibilityChanged(bool value) { visible = value; }
};
namespace webid {
struct AccountSelectionBubbleView : views::View {};
struct AccountSelectionModalView : views::View {};
struct AccountSelectionBubbleDelegate : views::BubbleDialogDelegate {
  std::unique_ptr<AccountSelectionBubbleView> contents;
  AccountSelectionBubbleDelegate(std::unique_ptr<AccountSelectionBubbleView> view, views::View* anchor_view)
      : contents(std::move(view)) { anchor = anchor_view; }
};
struct AccountSelectionModalDelegate : views::DialogDelegate {
  std::unique_ptr<AccountSelectionModalView> contents;
  explicit AccountSelectionModalDelegate(std::unique_ptr<AccountSelectionModalView> view)
      : contents(std::move(view)) {}
};
struct FedCmAccountSelectionView {
  enum class DialogType { BUBBLE, MODAL };
  DialogType dialog_type_;
  bool account_selection_view_ = true;
  views::View anchor;
  content::WebContents page;
  tabs::TabInterface tab;
  tabs::TabInterface* tab_ = &tab;
  views::Widget* current_widget = nullptr;
  std::optional<int> scoped_ignore_input_events_;
  std::unique_ptr<int> tab_accept_mouse_events_;
  std::unique_ptr<InputProtector> input_protector_ = std::make_unique<InputProtector>();
  bool can_show = true;
  int anchor_lookups = 0;
  std::unique_ptr<views::View> parked_dialog_view_;
  std::unique_ptr<views::WidgetDelegate> widget_delegate_;
  std::unique_ptr<ScopedPictureInPictureOcclusionObservation> pip_occlusion_observation_;
  explicit FedCmAccountSelectionView(DialogType type) : dialog_type_(type) {
    if (type == DialogType::BUBBLE) parked_dialog_view_ = std::make_unique<AccountSelectionBubbleView>();
    else parked_dialog_view_ = std::make_unique<AccountSelectionModalView>();
  }
  views::View* GetAnchorView() { ++anchor_lookups; return cio::hosted ? nullptr : &anchor; }
  content::WebContents* web_contents() { return &page; }
  std::unique_ptr<views::Widget> CreateDialogWidget();
  views::Widget* GetDialogWidget() { return current_widget; }
  void ShouldShowDialog(bool& visible) { assert(current_widget); visible = visible && can_show; }
  void ShowDialog(views::Widget*, std::unique_ptr<tabs::TabDialogManager::Params>);
  void UpdateDialogPosition();
  void UpdateDialogVisibility(bool requested_visibility);
  void HideDialogWidget();
  bool IsDialogManaged(views::Widget*);
};
#include "FedCmDialogFactory.inc"
#include "FedCmDialogRouting.inc"
}

int main() {
  using View = webid::FedCmAccountSelectionView;
  for (bool hosted : {true, false}) {
    cio::hosted = hosted;
    views::Widget host;
    views::Widget::host = hosted ? nullptr : &host;
    for (auto type : {View::DialogType::BUBBLE, View::DialogType::MODAL}) {
      View view(type);
      if (hosted) view.HideDialogWidget();  // A tab may deactivate before any dialog exists.
      auto widget = view.CreateDialogWidget();
      assert(widget);
      assert(view.pip_occlusion_observation_);
      assert(!view.parked_dialog_view_);
      assert(view.anchor_lookups == (!hosted && type == View::DialogType::BUBBLE ? 1 : 0));
      view.current_widget = widget.get();
      auto params = std::make_unique<tabs::TabDialogManager::Params>();
      params->disable_input = type == View::DialogType::MODAL;
      view.ShowDialog(widget.get(), std::move(params));
      view.UpdateDialogPosition();
      view.UpdateDialogVisibility(true);
      if (hosted) {
        assert(cio::visible);
        assert(view.scoped_ignore_input_events_.has_value() == (type == View::DialogType::MODAL));
        assert(!view.IsDialogManaged(widget.get()));
        view.HideDialogWidget();
        assert(!cio::visible);
        assert(!view.scoped_ignore_input_events_);
        assert(!view.input_protector_->visible);
        view.tab.active = false;
        view.UpdateDialogVisibility(true);
        assert(!cio::visible);
        view.tab.active = true;
        view.can_show = false;
        view.UpdateDialogVisibility(true);
        assert(!cio::visible);
        assert(view.tab.features.manager.calls == 0);
      } else {
        assert(view.IsDialogManaged(widget.get()));
        assert(view.tab.features.manager.calls == 4);
      }
    }
  }
  assert(extensions::SecurityDialogTracker::GetInstance()->tracked == 4);
  assert(cio::attachments == 2);
  assert(cio::positions == 2);
  puts("PASS: hosted/stock FedCM creation, modal input protection and visibility routing retain security tracking");
}
