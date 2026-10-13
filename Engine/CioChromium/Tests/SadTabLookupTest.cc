// Fixture for the actual FindContentsWebView body in the pinned overlay.
#include <cassert>
#include <cstdio>
#include <vector>

#define DCHECK(value) assert(value)
#define IS_MAC 1
#define BUILDFLAG(flag) flag
namespace content { struct WebContents {}; }
struct ContentsWebView {
  content::WebContents* contents;
  content::WebContents* web_contents() { return contents; }
};
struct NativeWindow {
  bool present = true;
  void* GetNativeWindow() { return present ? this : nullptr; }
};
struct BrowserView;
struct BrowserWindowInterface {
  NativeWindow* window = nullptr;
  BrowserView* view = nullptr;
  NativeWindow* GetWindow() { return window; }
};
struct BrowserView {
  std::vector<ContentsWebView*> views;
  static BrowserView* GetBrowserViewForBrowser(BrowserWindowInterface* browser) {
    return browser->view;
  }
  const auto& GetAllVisibleContentsWebViews() { return views; }
};
namespace tabs {
struct TabInterface {
  static inline TabInterface* current = nullptr;
  BrowserWindowInterface* browser;
  static TabInterface* MaybeGetFromContents(content::WebContents*) { return current; }
  BrowserWindowInterface* GetBrowserWindowInterface() { return browser; }
};
}
namespace cio {
bool hosted = false;
bool IsHostedBrowser() { return hosted; }
}

// Generated from the engine source by verify_renderer_crash.py, not a copy of
// the lookup implementation. The fixtures model a Cio NSWindow with no Views
// BrowserView, the exact invariant that aborted in the captured crash report.
#include "SadTabLookup.inc"

int main() {
  content::WebContents page, other_page;
  NativeWindow window;
  BrowserWindowInterface browser{&window, nullptr};
  tabs::TabInterface tab{&browser};
  tabs::TabInterface::current = &tab;
  cio::hosted = true;
  for (int i = 0; i < 10; ++i) {
    // Constructor, reinstallation and destructor all use this lookup.
    assert(FindContentsWebView(&page) == nullptr);
  }
  cio::hosted = false;
  ContentsWebView view{&page};
  BrowserView chrome_view{{&view}};
  browser.view = &chrome_view;
  assert(FindContentsWebView(&page) == &view);
  assert(FindContentsWebView(&other_page) == nullptr);
  browser.window = nullptr;
  assert(FindContentsWebView(&page) == nullptr);
  browser.window = &window;
  window.present = false;
  assert(FindContentsWebView(&page) == nullptr);
  tab.browser = nullptr;
  assert(FindContentsWebView(&page) == nullptr);
  tabs::TabInterface::current = nullptr;
  assert(FindContentsWebView(&page) == nullptr);
  puts("PASS: hosted crash/reinstall/cleanup avoids Views; stock Chrome lookup is preserved");
}
