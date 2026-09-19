//
//  BrowserBridge.mm
//  NativeBrowser
//
//  Objective-C++ implementation of the CEF browser boundary.
//

#import "BrowserBridge.h"

#import "CEFClientHandler.h"
#import "ShutdownTiming.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/internal/cef_mac.h"

namespace {

/// Renders into a parent view without stealing focus.
constexpr int kInitialWidth = 1280;
constexpr int kInitialHeight = 800;

}  // namespace

@implementation BrowserBridge {
  CefRefPtr<CEFClientHandler> _client;
  /// Parent view the Chromium browser view is attached to. The container owns
  /// the view; the bridge must not keep it alive.
  __weak NSView *_parentView;
  BOOL _closed;
  BOOL _closeRequested;
  /// YES once the Chromium view has been released. Releasing it more than once
  /// is not safe: the first release is what destroys the browser, so a second
  /// pass would run against a browser that is already being torn down.
  BOOL _viewReleased;
  NSSize _lastReportedSize;
}

- (instancetype)initWithParentView:(NSView *)view {
  self = [super init];
  if (self) {
    _parentView = view;
    _client = new CEFClientHandler(self);
  }
  return self;
}

- (void)dealloc {
  // CefShutdown() requires that no browser outlives the application; a bridge
  // that is deallocated with a live browser means -close was skipped.
  if (_client->browser()) {
    NSLog(@"[browser] bridge deallocated with a live Chromium browser");
  }
}

- (BOOL)isClosed {
  return _closed;
}

#pragma mark - Navigation

- (void)loadURL:(NSString *)url {
  if (_closed || url.length == 0) {
    return;
  }
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    if (CefRefPtr<CefFrame> frame = browser->GetMainFrame()) {
      frame->LoadURL(std::string(url.UTF8String));
    }
    return;
  }
  [self createBrowserWithURL:url];
}

- (void)goBack {
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    browser->GoBack();
  }
}

- (void)goForward {
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    browser->GoForward();
  }
}

- (void)reload {
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    browser->Reload();
  }
}

- (void)stopLoading {
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    browser->StopLoad();
  }
}

#pragma mark - View integration

- (void)setFocus:(BOOL)focused {
  if (_closeRequested) {
    NBShutdownTimingReport(@"focus:refused(closeRequested)", 0);
    return;
  }
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  host->SetFocus(focused);

  NSView *browserView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(host->GetWindowHandle());
  if (browserView.window != nil) {
    if (focused) {
      // Chromium only receives key events when its view is first responder.
      [browserView.window makeFirstResponder:browserView];
    } else if (browserView.window.firstResponder == browserView) {
      [browserView.window makeFirstResponder:nil];
    }
  }
  NSLog(@"[browser] focus %@", focused ? @"granted" : @"released");
}

- (void)resizeToBounds:(NSRect)bounds {
  if (_closeRequested) {
    NBShutdownTimingReport(@"resize:refused(closeRequested)", 0);
    return;
  }
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    return;
  }
  NSView *browserView =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  if (browserView != nil) {
    // The browser view fills its container; AppKit keeps it in sync, and
    // WasResized() makes Chromium re-layout the page at the new size.
    [browserView setFrame:_parentView.bounds];
  }
  browser->GetHost()->WasResized();
  if (!NSEqualSizes(_lastReportedSize, _parentView.bounds.size)) {
    _lastReportedSize = _parentView.bounds.size;
    NSLog(@"[browser] resized: container=%.0fx%.0f view=%.0fx%.0f",
          NSWidth(_parentView.bounds), NSHeight(_parentView.bounds),
          NSWidth(browserView.bounds), NSHeight(browserView.bounds));
  }
}

/// Moves the browser view into a new container.
///
/// Refused once a close has been requested: SwiftUI can re-create the
/// representable's container while the browser is being torn down, and moving
/// the Chromium view at that point takes it away from the close sequence that
/// CEF is running, so DoClose/OnBeforeClose never arrive (observed as a hang
/// until CefShutdown forces the teardown).
- (void)reparentToView:(NSView *)view {
  if (view == nil || _closed || _closeRequested) {
    NBShutdownTimingReport(
        _closeRequested ? @"reparent:refused(closeRequested)" : @"reparent:refused", 0);
    return;
  }
  _parentView = view;
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    return;
  }
  NSView *browserView =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  if (browserView == nil) {
    return;
  }
  [browserView removeFromSuperview];
  browserView.frame = view.bounds;
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [view addSubview:browserView];
  browser->GetHost()->WasResized();
  NSLog(@"[browser] re-parented the Chromium view into a new container");
}

#pragma mark - Lifecycle

- (void)close {
  if (_closed || _closeRequested) {
    return;
  }
  _closeRequested = YES;

  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    // Never created (or already gone): release the bridge immediately.
    [self browserDidClose];
    return;
  }
  NBShutdownTimingMark(@"T1-CloseBrowser");
  NSLog(@"[browser] closing Chromium browser %d", browser->GetIdentifier());

  // force_close: skip the beforeunload handler so quitting is never blocked.
  // The browser is destroyed by CEFClientHandler::DoClose() ->
  // -completeClose, which releases the Chromium view. Reported as a real
  // timestamp (not a mark) so a CloseBrowser that does not return is visible.
  NBShutdownTimingReport(@"CloseBrowser:begin", NBShutdownTimingNow());
  browser->GetHost()->CloseBrowser(/*force_close=*/true);
  NBShutdownTimingReport(@"CloseBrowser:end", NBShutdownTimingNow());
  NSLog(@"[browser] CloseBrowser returned");
}

- (void)releaseBrowserView {
  [self completeClose];
}

/// Completes a close that CEF has started: the Chromium view is released so
/// that CEF destroys the browser object (ARCHITECTURE.md section 26).
- (void)completeClose {
  if (_viewReleased) {
    return;
  }
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    return;
  }
  _viewReleased = YES;
  NBShutdownTimingMark(@"T2");

  // Detaching the Chromium view is what actually destroys the browser: CEF
  // implements AlloyBrowserHostImpl::WindowDestroyed() in
  // CefBrowserHostView's -dealloc, so the view has to deallocate, not merely
  // leave the hierarchy.
  //
  // The autorelease pool and the nil assignment matter: without them ARC keeps
  // a strong reference to the view alive until the surrounding pool drains, the
  // view never deallocates, and CEF never destroys the browser (OnBeforeClose
  // then only arrives during CefShutdown, which makes quitting hang).
  @autoreleasepool {
    NSView *browserView =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    // Resign the native responder before detaching the host view. Chromium's
    // focused content and AppKit's input context can otherwise retain it.
    browser->GetHost()->SetFocus(false);
    [browserView.window makeFirstResponder:nil];
    [browserView removeFromSuperview];
    browserView = nil;
  }
}

#pragma mark - Browser creation

- (void)createBrowserWithURL:(NSString *)url {
  NSView *parent = _parentView;
  if (parent == nil) {
    NSLog(@"[browser] cannot create a browser without a parent view");
    return;
  }

  NSRect bounds = parent.bounds;
  if (NSIsEmptyRect(bounds)) {
    bounds = NSMakeRect(0, 0, kInitialWidth, kInitialHeight);
  }

  CefWindowInfo windowInfo;
  windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(parent),
                        CefRect(0, 0, static_cast<int>(NSWidth(bounds)),
                                static_cast<int>(NSHeight(bounds))));

  CefBrowserSettings settings;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);

  CefBrowserHost::CreateBrowser(windowInfo, _client, std::string(url.UTF8String),
                                settings, nullptr, nullptr);
  NSLog(@"[browser] creating Chromium browser for %@", url);
}

#pragma mark - Events from the CEF layer

- (void)browserDidCreate {
  if (_closed) {
    return;
  }
  // Chromium attaches its own view; keep it filling the container.
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    NSView *browserView =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    if (browserView != nil) {
      browserView.frame = _parentView.bounds;
      browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
  }
  NSLog(@"[browser] Chromium browser created");
  [self.delegate browserBridgeDidCreateBrowser:self];
}

- (void)browserDidUpdateTitle:(NSString *)title {
  [self.delegate browserBridge:self didUpdateTitle:title];
}

- (void)browserDidUpdateURL:(NSString *)url {
  [self.delegate browserBridge:self didUpdateURL:url];
}

- (void)browserDidUpdateLoadingState:(BOOL)isLoading
                           canGoBack:(BOOL)canGoBack
                        canGoForward:(BOOL)canGoForward {
  [self.delegate browserBridge:self
          didUpdateLoadingState:isLoading
                      canGoBack:canGoBack
                   canGoForward:canGoForward];
}

- (void)browserDidUpdateLoadingProgress:(double)progress {
  [self.delegate browserBridge:self didUpdateLoadingProgress:progress];
}

- (void)browserDidFailLoadWithError:(NSString *)errorText
                          errorCode:(NSInteger)errorCode
                          failedURL:(NSString *)failedURL {
  [self.delegate browserBridge:self
          didFailLoadWithError:errorText
                     errorCode:errorCode
                     failedURL:failedURL];
}

- (void)browserDidClose {
  if (_closed) {
    return;
  }
  _closed = YES;
  NBShutdownTimingMark(@"T3");
  NSLog(@"[browser] Chromium browser destroyed");
  [self.delegate browserBridgeDidClose:self];
}

@end
