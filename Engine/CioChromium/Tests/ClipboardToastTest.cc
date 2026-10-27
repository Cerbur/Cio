// The verifier extracts real Chromium admission/copy bodies into the include.
// Only the surrounding renderer, preferences and window services are fixtures.
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <utility>

#define IS_MAC 1
#define IS_ANDROID 0
#define BUILDFLAG(flag) flag
#define CHECK_IS_TEST() do { \
  std::fputs("CHECK_IS_TEST: toast has no Chrome Views anchor\n", stderr); \
  std::abort(); \
} while (false)

namespace cio {
bool hosted = true;
bool IsHostedBrowser() { return hosted; }
}
namespace views { struct View {}; }
namespace webui_browser { bool IsWebUIBrowserEnabled() { return false; } }
namespace toasts {
enum class ToastAlertLevel { kAll, kActionable };
enum class ToastCloseReason { kPreempted };
}
namespace prefs { constexpr auto kToastAlertLevel = "toast.alert_level"; }
struct LocalState {
  int level = 0;
  int GetInteger(const char*) { return level; }
};
struct BrowserProcess {
  LocalState state;
  LocalState* local_state() { return &state; }
} process;
auto* g_browser_process = &process;
enum class ToastId { kImageCopied, kLinkCopied, kActionable };
struct ToastParams {
  ToastId toast_id;
  explicit ToastParams(ToastId id) : toast_id(id) {}
};
struct ToastSpecification {
  bool actionable = false;
  bool is_actionable() const { return actionable; }
  bool is_global_scope() const { return false; }
};
struct ToastRegistry {
  ToastSpecification plain, actionable{true};
  const ToastSpecification* GetToastSpecification(ToastId id) const {
    return id == ToastId::kActionable ? &actionable : &plain;
  }
};
int failed = 0, triggered = 0;
void RecordToastFailedToShow(ToastId) { ++failed; }
void RecordToastTriggeredToShow(ToastId) { ++triggered; }
struct ToastController {
  ToastRegistry registry;
  const ToastRegistry* toast_registry_ = &registry;
  views::View anchor;
  int shown = 0, closed = 0, queued = 0;
  bool CanShowToast(ToastId) const;
  bool MaybeShowToast(ToastParams);
  void CreateToast(ToastParams, const ToastSpecification*);
  void ShowToast(ToastParams params) {
    ++shown;
    const auto* spec = registry.GetToastSpecification(params.toast_id);
    CreateToast(std::move(params), spec);
  }
  void CloseToast(toasts::ToastCloseReason) { ++closed; }
  bool IsShowingToast() const { return false; }
  void QueueToast(ToastParams) { ++queued; }
  views::View* GetAnchorView(bool) { return cio::hosted ? nullptr : &anchor; }
};
namespace toast_features {
bool enabled = true;
constexpr int kImageCopiedToast = 0;
bool IsEnabled(int) { return enabled; }
}
namespace enterprise_data_protection {
bool allowed = true;
bool IsClipboardCopyAllowedByPolicyForUI(void*) { return allowed; }
}
struct RenderFrameHost {
  int copies = 0;
  void CopyImageAt(int x, int y) { assert(x == 17 && y == 23); ++copies; }
};
struct RenderViewContextMenu {
  struct { int x = 17, y = 23; } params_;
  RenderFrameHost* frame;
  ToastController* controller;
  RenderFrameHost* GetRenderFrameHost() { return frame; }
  void* GetWebContentsForDataControls() { return nullptr; }
  ToastController* GetToastController() { return controller; }
  void ExecCopyImageAt();
};

#include "ClipboardToast.inc"

int main() {
  ToastController controller;
  RenderFrameHost frame;
  RenderViewContextMenu menu{{}, &frame, &controller};
  // Exact reported chain: copy dispatch -> toast admission -> missing anchor.
  for (int i = 0; i < 10; ++i) menu.ExecCopyImageAt();
  assert(frame.copies == 10);
  assert(controller.shown == 0 && controller.closed == 0 && controller.queued == 0);
  assert(triggered == 0 && failed == 10);
  for (auto id : {ToastId::kImageCopied, ToastId::kLinkCopied, ToastId::kActionable}) {
    assert(!controller.CanShowToast(id));
    assert(!controller.MaybeShowToast(ToastParams(id)));
  }
  menu.frame = nullptr;
  menu.ExecCopyImageAt();
  assert(frame.copies == 10);
  menu.frame = &frame;
  menu.controller = nullptr;
  menu.ExecCopyImageAt();
  assert(frame.copies == 11);
  menu.controller = &controller;
  // Stock Chrome retains toast admission, feature and enterprise UI checks.
  cio::hosted = false;
  menu.ExecCopyImageAt();
  assert(frame.copies == 12 && controller.shown == 1);
  toast_features::enabled = false;
  menu.ExecCopyImageAt();
  assert(frame.copies == 13 && controller.shown == 1);
  toast_features::enabled = true;
  enterprise_data_protection::allowed = false;
  menu.ExecCopyImageAt();
  assert(frame.copies == 14 && controller.shown == 1);
  process.state.level = static_cast<int>(toasts::ToastAlertLevel::kActionable);
  assert(!controller.MaybeShowToast(ToastParams(ToastId::kImageCopied)));
  assert(controller.MaybeShowToast(ToastParams(ToastId::kActionable)));
  assert(controller.shown == 2);
  std::puts("PASS: image-copy dispatch survives missing hosted Views anchor; stock toast policy preserved");
}
