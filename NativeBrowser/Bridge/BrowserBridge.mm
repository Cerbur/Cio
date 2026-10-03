//
//  BrowserBridge.mm
//  NativeBrowser
//
//  Objective-C++ implementation of the CEF browser boundary.
//

#import "BrowserBridge.h"

#import "CEFClientHandler.h"
#import "ShutdownTiming.h"

#include <cstdio>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_frame.h"
#include "include/cef_parser.h"
#include "include/cef_request_handler.h"
#include "include/cef_ssl_info.h"
#include "include/cef_values.h"
#include "include/internal/cef_mac.h"

namespace {

/// Renders into a parent view without stealing focus.
constexpr int kInitialWidth = 1280;
constexpr int kInitialHeight = 800;

/// YES when `responder` is `view` or lives inside its subtree.
///
/// The window's shared field editor is deliberately not treated as part of any
/// browser view: AppKit reuses one NSTextView for every text field in the
/// window, so a browser teardown must never mistake the address field's editor
/// for its own (Milestone 3 section 17).
BOOL NBResponderBelongsToView(NSResponder *responder, NSView *view) {
  if (responder == nil || view == nil) {
    return NO;
  }
  if ([responder isKindOfClass:[NSView class]]) {
    return [(NSView *)responder isDescendantOf:view];
  }
  return NO;
}

/// The inspector has independent callbacks and a child view, never a native
/// top-level window. Handle its close ourselves so CEF cannot close the shell.
class NativeBrowserDevToolsClient final : public CefClient,
                                         public CefLifeSpanHandler,
                                         public CefFocusHandler,
                                         public CefRequestHandler,
                                         public CefDevToolsMessageObserver {
 public:
  NativeBrowserDevToolsClient(BrowserBridge *bridge, CefRefPtr<CefBrowser> inspected)
      : bridge_(bridge), inspected_(inspected), pending_ids_([NSMutableDictionary dictionary]) {}
  CefRefPtr<CefBrowser> browser() const { return browser_; }
  void Disconnect() {
    registration_ = nullptr;
    inspected_ = nullptr;
    [pending_ids_ removeAllObjects];
  }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool user_gesture, bool is_redirect) override {
    return request->GetURL().ToString() != "devtools://devtools/bundled/devtools_app.html";
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                     int popup_id, const CefString& target_url, const CefString& target_frame_name,
                     WindowOpenDisposition disposition, bool user_gesture,
                     const CefPopupFeatures& features, CefWindowInfo& info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) override {
    return true;
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (source != PID_RENDERER || message->GetName() != "NativeBrowser.Inspector" ||
        !browser_ || !browser_->IsSame(browser) || !frame->IsMain() ||
        frame->GetURL().ToString() != "devtools://devtools/bundled/devtools_app.html") return false;
    auto args = message->GetArgumentList();
    if (args->GetSize() != 2) return true;
    if (args->GetString(0) == "close") { [bridge_ closeDevTools]; return true; }
    if (args->GetString(0) != "protocol" || !inspected_ || !inspected_->IsValid()) return true;
    // The shell also uses CDP for appearance. Keep its response IDs separate
    // from the frontend, which starts its own sequence at 1 on every reopen.
    auto value = CefParseJSON(args->GetString(1), JSON_PARSER_RFC);
    auto dictionary = value ? value->GetDictionary() : nullptr;
    if (!dictionary || !dictionary->HasKey("id")) return true;
    const int id = next_id_++;
    pending_ids_[@(id)] = @(dictionary->GetInt("id"));
    dictionary->SetInt("id", id);
    std::string json = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
    inspected_->GetHost()->SendDevToolsMessage(json.data(), json.size());
    return true;
  }

  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* message, size_t size) override {
    if (!browser_) return true;
    @autoreleasepool {
      NSData* data = [NSData dataWithBytes:message length:size];
      NSMutableDictionary* json = [NSJSONSerialization JSONObjectWithData:data
          options:NSJSONReadingMutableContainers error:nil];
      if (![json isKindOfClass:[NSMutableDictionary class]]) return true;
      if (NSNumber* id = json[@"id"]) {
        NSNumber* original = pending_ids_[id];
        if (!original) return true;
        json[@"id"] = original;
        [pending_ids_ removeObjectForKey:id];
      }
      NSData* payload = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
      NSString* encoded = [payload base64EncodedStringWithOptions:0];
      NSString* script = [NSString stringWithFormat:
          @"globalThis.InspectorFrontendAPI?.dispatchMessage(new TextDecoder().decode(Uint8Array.from(atob('%@'),c=>c.charCodeAt(0))))", encoded];
      browser_->GetMainFrame()->ExecuteJavaScript(std::string(script.UTF8String), "", 0);
    }
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
    if (inspected_ && inspected_->IsValid())
      registration_ = inspected_->GetHost()->AddDevToolsMessageObserver(this);
    browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
    [bridge_ devToolsDidCreate];
  }

  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override {
    return ![bridge_ devToolsAllowsFocus];
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    @autoreleasepool {
      NSView *view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
      browser->GetHost()->SetFocus(false);
      if (NBResponderBelongsToView(view.window.firstResponder, view)) {
        [view.window makeFirstResponder:nil];
      }
      [view removeFromSuperview];
      view = nil;
    }
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    Disconnect();
    browser_ = nullptr;
    [bridge_ devToolsDidClose];
  }

 private:
  __weak BrowserBridge *bridge_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefBrowser> inspected_;
  CefRefPtr<CefRegistration> registration_;
  __strong NSMutableDictionary<NSNumber*, NSNumber*>* pending_ids_;
  int next_id_ = 1000000000;
  IMPLEMENT_REFCOUNTING(NativeBrowserDevToolsClient);
};

}  // namespace

@interface BrowserConnectionInfo ()
@property(nonatomic, readwrite, copy) NSString *url;
@property(nonatomic, readwrite) BOOL usesTLS;
@property(nonatomic, readwrite) BOOL certificateValid;
@property(nonatomic, readwrite) BOOL hasInsecureContent;
@property(nonatomic, readwrite, copy) NSArray<NSData *> *certificateChain;
@end

@implementation BrowserConnectionInfo
@end

@implementation BrowserBridge {
  CefRefPtr<CEFClientHandler> _client;
  CefRefPtr<NativeBrowserDevToolsClient> _devToolsClient;
  __weak NSView *_devToolsParentView;
  BOOL _devToolsCloseRequested;
  BOOL _closePageAfterDevTools;
  BOOL _closeNotificationDelivered;
  /// Parent view the Chromium browser view is attached to. The container owns
  /// the view; the bridge must not keep it alive.
  __weak NSView *_parentView;
  BOOL _closed;
  /// YES while an ordinary tab-close request is waiting for beforeunload.
  /// The workspace remains intact until CEF reports acceptance.
  BOOL _ordinaryCloseRequested;
  /// YES once CEF has accepted the close and DoClose/OnBeforeClose is expected.
  BOOL _closeCommitted;
  BOOL _closeRequested;
  /// YES once the Chromium view has been released. Releasing it more than once
  /// is not safe: the first release is what destroys the browser, so a second
  /// pass would run against a browser that is already being torn down.
  BOOL _viewReleased;
  /// YES when this close is part of application termination, in which case the
  /// window's first responder is released unconditionally (the Milestone 2
  /// Cmd+Q fix). See -closeForApplicationTermination:.
  BOOL _releasesFirstResponderOnClose;
  /// The native confirmation currently resolving CEF's beforeunload callback.
  /// Its result is explicit; dialog dismissal is never interpreted as a close
  /// choice.
  __strong NSAlert *_beforeUnloadAlert;
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
  if (_client != nullptr && _client->browser()) {
    fprintf(stderr, "[browser] bridge deallocated with a live Chromium browser\n");
  }
}

- (BOOL)isClosed {
  return _closed;
}

- (int)browserIdentifier {
  CefRefPtr<CefBrowser> browser = _client->browser();
  return browser ? browser->GetIdentifier() : -1;
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

- (BOOL)showDevToolsInView:(NSView *)view {
  if (_closed || _closeRequested || _ordinaryCloseRequested ||
      _devToolsCloseRequested || view.window == nil) return NO;
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) return NO;
  _devToolsParentView = view;
  if (_devToolsClient) return YES;
  _devToolsClient = new NativeBrowserDevToolsClient(self, browser);
  CefWindowInfo windowInfo;
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(view),
      CefRect(0, 0, static_cast<int>(NSWidth(view.bounds)),
                    static_cast<int>(NSHeight(view.bounds))));
  CefBrowserSettings settings;
  // CEF 152's ShowDevTools creates a Chrome-style window and CHECKs if macOS
  // SetAsChild forces Alloy. Host the bundled frontend as a regular child and
  // connect its protocol using CEF's in-process observer API instead.
  auto extraInfo = CefDictionaryValue::Create();
  extraInfo->SetBool("nativeBrowserInspector", true);
  bool created = CefBrowserHost::CreateBrowser(windowInfo, _devToolsClient,
      "devtools://devtools/bundled/devtools_app.html", settings, extraInfo,
      browser->GetHost()->GetRequestContext());
  if (!created) {
    _devToolsClient = nullptr;
    _devToolsParentView = nil;
  }
  return created;
}

- (void)closeDevTools {
  if (!_devToolsClient) return;
  _devToolsCloseRequested = YES;
  _devToolsClient->Disconnect();
  if (CefRefPtr<CefBrowser> inspector = _devToolsClient->browser()) {
    inspector->GetHost()->CloseBrowser(/*force_close=*/true);
  }
  // A close before OnAfterCreated is remembered and completed by that callback.
}

- (void)resizeDevTools {
  if (!_devToolsClient || _devToolsCloseRequested) return;
  CefRefPtr<CefBrowser> inspector = _devToolsClient->browser();
  NSView *parent = _devToolsParentView;
  if (!inspector || !parent) return;
  NSView *view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(inspector->GetHost()->GetWindowHandle());
  view.frame = parent.bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  inspector->GetHost()->WasResized();
}

- (void)reparentDevToolsToView:(NSView *)view {
  if (!_devToolsClient || _closed || _closeRequested || _ordinaryCloseRequested ||
      _devToolsCloseRequested) return;
  _devToolsParentView = view;
  if (CefRefPtr<CefBrowser> inspector = _devToolsClient->browser()) {
    NSView *child = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(inspector->GetHost()->GetWindowHandle());
    [child removeFromSuperview];
    [view addSubview:child];
    [self resizeDevTools];
  }
}

- (void)devToolsDidCreate {
  if (_closed || _closeRequested || _ordinaryCloseRequested || _devToolsCloseRequested) {
    [self closeDevTools];
    return;
  }
  [self resizeDevTools];
}

- (BOOL)devToolsAllowsFocus {
  NSView *parent = _devToolsParentView;
  return !_closed && !_closeRequested && !_ordinaryCloseRequested &&
      !_devToolsCloseRequested && parent.window != nil && !parent.isHiddenOrHasHiddenAncestor;
}

- (void)devToolsDidClose {
  _devToolsClient = nullptr;
  _devToolsCloseRequested = NO;
  _devToolsParentView = nil;
  [self.delegate browserBridgeDidCloseDevTools:self];
  if (_closePageAfterDevTools) {
    _closePageAfterDevTools = NO;
    [self closeForApplicationTermination:YES];
  }
  [self notifyCloseWhenAllBrowsersAreClosed];
}

- (void)notifyCloseWhenAllBrowsersAreClosed {
  if (!_closed || _devToolsClient || _closeNotificationDelivered) return;
  _closeNotificationDelivered = YES;
  NBShutdownTimingMark(@"T3");
  [self.delegate browserBridgeDidClose:self];
}

- (BrowserConnectionInfo *)connectionInfo {
  if (_closed || _closeRequested) return nil;
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) return nil;
  CefRefPtr<CefNavigationEntry> entry = browser->GetHost()->GetVisibleNavigationEntry();
  if (!entry || !entry->IsValid()) return nil;

  BrowserConnectionInfo *info = [[BrowserConnectionInfo alloc] init];
  info.url = [NSString stringWithUTF8String:entry->GetURL().ToString().c_str()] ?: @"";
  info.certificateChain = @[];
  CefRefPtr<CefSSLStatus> ssl = entry->GetSSLStatus();
  if (!ssl) return info;
  info.usesTLS = ssl->IsSecureConnection();
  info.hasInsecureContent = ssl->GetContentStatus() != SSL_CONTENT_NORMAL_CONTENT;
  CefRefPtr<CefX509Certificate> certificate = ssl->GetX509Certificate();
  info.certificateValid = certificate && !CefIsCertStatusError(ssl->GetCertStatus());
  if (certificate) {
    NSMutableArray<NSData *> *chain = [NSMutableArray array];
    auto appendDER = [&](CefRefPtr<CefBinaryValue> value) {
      if (!value || value->GetSize() == 0) return;
      NSMutableData *data = [NSMutableData dataWithLength:value->GetSize()];
      if (value->GetData(data.mutableBytes, data.length, 0) == data.length) {
        [chain addObject:[data copy]];
      }
    };
    appendDER(certificate->GetDEREncoded());
    CefX509Certificate::IssuerChainBinaryList issuers;
    certificate->GetDEREncodedIssuerChain(issuers);
    for (auto issuer : issuers) appendDER(issuer);
    info.certificateChain = chain;
  }
  return info;
}

- (void)startDownloadURL:(NSString *)url {
  if (_closed || url.length == 0) {
    return;
  }
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    browser->GetHost()->StartDownload(std::string(url.UTF8String));
  }
}

- (void)sendTestUserActivation {
  if (_closed) {
    return;
  }
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    CefMouseEvent event;
    event.x = kInitialWidth / 2;
    event.y = kInitialHeight / 2;
    event.modifiers = 0;
    browser->GetHost()->SendMouseClickEvent(
        event, MBT_LEFT, /*mouseUp=*/false, /*clickCount=*/1);
    browser->GetHost()->SendMouseClickEvent(
        event, MBT_LEFT, /*mouseUp=*/true, /*clickCount=*/1);
  }
}

#pragma mark - View integration

- (void)setFocus:(BOOL)focused {
  if (_closeRequested || _ordinaryCloseRequested) {
    NBShutdownTimingReport(@"focus:refused(closeRequested)", 0);
    return;
  }
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  // Returning to the page, switching tabs or editing the address must also
  // release the inspector's CEF focus. It shares this session's native shell.
  if (_devToolsClient) {
    if (CefRefPtr<CefBrowser> inspector = _devToolsClient->browser()) {
      inspector->GetHost()->SetFocus(false);
      NSView *view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(inspector->GetHost()->GetWindowHandle());
      if (!focused && NBResponderBelongsToView(view.window.firstResponder, view)) {
        [view.window makeFirstResponder:nil];
      }
    }
  }
  host->SetFocus(focused);

  NSView *browserView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(host->GetWindowHandle());
  if (browserView.window != nil) {
    if (focused) {
      // CEF selects its native render responder through SetFocus. The window
      // handle is the browser's outer view; forcing that wrapper to become
      // first responder can displace Chromium's actual keyboard input view.
      fprintf(stderr, "[browser] focus granted\n");
    } else if (NBResponderBelongsToView(browserView.window.firstResponder, browserView)) {
      // Only this browser's own responder is cleared. Releasing focus from a
      // tab that is being switched away from must not disturb the native
      // address field, whose field editor is the window's first responder.
      [browserView.window makeFirstResponder:nil];
    }
  }
}

- (BOOL)setDarkAppearance:(BOOL)dark {
  if (_closed) {
    return NO;
  }
  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    return NO;
  }

  // The request-context color variant changes Chromium's own theme, but in
  // Alloy it does not update a page's prefers-color-scheme media query. Set
  // that media feature through Chromium's supported DevTools protocol instead.
  CefRefPtr<CefDictionaryValue> feature = CefDictionaryValue::Create();
  feature->SetString("name", "prefers-color-scheme");
  feature->SetString("value", dark ? "dark" : "light");
  CefRefPtr<CefListValue> features = CefListValue::Create();
  features->SetDictionary(0, feature);
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetList("features", features);
  return browser->GetHost()->ExecuteDevToolsMethod(
             0, "Emulation.setEmulatedMedia", params) != 0;
}

- (void)resizeToBounds:(NSRect)bounds {
  if (_closeRequested || _ordinaryCloseRequested) {
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
  if (view == nil || _closed || _closeRequested || _ordinaryCloseRequested) {
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
}

#pragma mark - Lifecycle

- (void)closeForApplicationTermination:(BOOL)applicationTerminating {
  if (_closed) {
    return;
  }

  if (!applicationTerminating) {
    if (_closeRequested || _ordinaryCloseRequested) {
      return;
    }
    _ordinaryCloseRequested = YES;
    _releasesFirstResponderOnClose = NO;
  } else {
    // Termination overrides a pending ordinary close. It is the only path that
    // may bypass beforeunload and cancel active downloads immediately.
    [self dismissBeforeUnloadDialogForApplicationTermination];
    _ordinaryCloseRequested = NO;
    _client->CancelActiveDownloads();
    _closeRequested = YES;
    _releasesFirstResponderOnClose = YES;
    // Finish the inspector and release its inspected-browser reference before
    // starting the page teardown. CefShutdown must not see a protocol observer
    // or another browser retaining a page whose OnBeforeClose already ran.
    if (_devToolsClient) {
      _closePageAfterDevTools = YES;
      [self closeDevTools];
      return;
    }
  }

  CefRefPtr<CefBrowser> browser = _client->browser();
  if (!browser) {
    // Never created (or already gone): an ordinary request is accepted because
    // there is no renderer that can cancel it.
    if (!applicationTerminating) {
      [self browserDidAcceptClose];
    }
    [self browserDidClose];
    return;
  }
  NBShutdownTimingMark(@"T1-CloseBrowser");
  NBShutdownTimingReport(@"CloseBrowser:begin", NBShutdownTimingNow());
  if (applicationTerminating) {
    // force_close: skip the beforeunload handler so quitting is never blocked.
    browser->GetHost()->CloseBrowser(/*force_close=*/true);
  } else {
    // CloseBrowser(false) is the documented cancelable request and enters
    // CefJSDialogHandler::OnBeforeUnloadDialog; the explicit native response
    // below then decides whether to force the final close.
    NBShutdownTimingReport(@"CloseBrowser:cancelable", 0);
    browser->GetHost()->CloseBrowser(/*force_close=*/false);
  }
  NBShutdownTimingReport(@"CloseBrowser:end", NBShutdownTimingNow());
}

- (void)releaseBrowserView {
  // This escape hatch is reserved for deterministic self-tests after a
  // termination close has already been requested. Production shutdown waits
  // for CEF's typed OnBeforeClose path and never calls it as a timeout.
  if (!_closeRequested) {
    return;
  }
  // A self-test may reach this hook after DoClose has detached the view but
  // before CEF has completed the browser's close sequence. Re-issue the
  // force-close request while retaining the browser handle, then perform the
  // idempotent view release. Production termination never calls this hook.
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    browser->GetHost()->CloseBrowser(/*force_close=*/true);
  }
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
  [self closeDevTools];
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
    // The browser being closed always releases its own CEF focus, so two
    // Chromium browsers never both believe they own the keyboard.
    browser->GetHost()->SetFocus(false);
    [self releaseFirstResponderIfOwnedByView:browserView];
    [browserView removeFromSuperview];
    browserView = nil;
  }
}

/// Clears AppKit's first responder, but only when that belongs to this close.
///
/// Milestone 2 cleared it unconditionally, because during Cmd+Q the whole
/// application is going away and Chromium's focused content (and AppKit's input
/// context) can otherwise retain the host view and stall teardown. That fix is
/// preserved through `_releasesFirstResponderOnClose`, which the application
/// termination path sets.
///
/// With several browsers in one window the unconditional clear is no longer
/// always right: closing a *background* tab must not take the keyboard away from
/// the active tab, and it must not disturb the native address field, whose field
/// editor is the window's first responder. Outside termination the responder is
/// therefore only cleared when it actually belongs to the view being destroyed.
- (void)releaseFirstResponderIfOwnedByView:(NSView *)browserView {
  NSWindow *window = browserView.window;
  if (window == nil) {
    return;
  }
  if (_releasesFirstResponderOnClose ||
      NBResponderBelongsToView(window.firstResponder, browserView)) {
    [window makeFirstResponder:nil];
  }
}

#pragma mark - Browser creation

- (void)createBrowserWithURL:(NSString *)url {
  NSView *parent = _parentView;
  if (parent == nil) {
    fprintf(stderr, "[browser] cannot create a browser without a parent view\n");
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
  // Match the AppKit container while Chromium has no document pixels yet.
  // A fixed white base causes a bright frame when opening a tab in dark mode.
  __block NSColor *background = nil;
  [parent.effectiveAppearance performAsCurrentDrawingAppearance:^{
    background = [[NSColor underPageBackgroundColor]
        colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
  }];
  CGFloat red = 1, green = 1, blue = 1, alpha = 1;
  [background getRed:&red green:&green blue:&blue alpha:&alpha];
  settings.background_color = CefColorSetARGB(
      255, static_cast<int>(red * 255 + 0.5),
      static_cast<int>(green * 255 + 0.5),
      static_cast<int>(blue * 255 + 0.5));

  // Chromium receives the original, complete URL.
  CefBrowserHost::CreateBrowser(windowInfo, _client, std::string(url.UTF8String),
                                settings, nullptr, nullptr);
  // The URL is deliberately absent here: a browser URL may carry a token or an
  // OAuth code. BrowserSession reports the load through the centralized
  // sanitizer instead.
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
  [self.delegate browserBridgeDidCreateBrowser:self];
}

- (void)browserDidUpdateTitle:(NSString *)title {
  [self.delegate browserBridge:self didUpdateTitle:title];
}

- (void)browserDidUpdateFaviconURLs:(NSArray<NSString *> *)urls {
  [self.delegate browserBridge:self didUpdateFaviconURLs:urls];
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

- (void)browserDidFinishMainFrameLoadWithURL:(NSString *)url {
  [self.delegate browserBridge:self didFinishMainFrameLoadWithURL:url];
}

- (NSString *)downloadDestinationPathForIdentifier:(NSInteger)downloadIdentifier
                                          sourceURL:(NSString *)sourceURL
                                    suggestedFileName:(NSString *)suggestedFileName
                                 cefSuggestedFileName:(NSString *)cefSuggestedFileName
                                  contentDisposition:(NSString *)contentDisposition
                                          mimeType:(NSString *)mimeType
                                       originalURL:(NSString *)originalURL {
  return [self.delegate browserBridge:self
      destinationPathForDownloadIdentifier:downloadIdentifier
                                 sourceURL:sourceURL
                           suggestedFileName:suggestedFileName
                        cefSuggestedFileName:cefSuggestedFileName
                         contentDisposition:contentDisposition
                                 mimeType:mimeType
                              originalURL:originalURL];
}

- (void)browserDidUpdateDownloadWithIdentifier:(NSInteger)downloadIdentifier
                                      sourceURL:(NSString *)sourceURL
                                suggestedFileName:(NSString *)suggestedFileName
                              cefSuggestedFileName:(NSString *)cefSuggestedFileName
                               contentDisposition:(NSString *)contentDisposition
                                       mimeType:(NSString *)mimeType
                                    originalURL:(NSString *)originalURL
                                destinationPath:(NSString *)destinationPath
                                   receivedBytes:(long long)receivedBytes
                                      totalBytes:(long long)totalBytes
                                   hasTotalBytes:(BOOL)hasTotalBytes
                                    isInProgress:(BOOL)isInProgress
                                      isComplete:(BOOL)isComplete
                                      isCanceled:(BOOL)isCanceled
                                   isInterrupted:(BOOL)isInterrupted {
  [self.delegate browserBridge:self
      didUpdateDownloadWithIdentifier:downloadIdentifier
                            sourceURL:sourceURL
                      suggestedFileName:suggestedFileName
                    cefSuggestedFileName:cefSuggestedFileName
                     contentDisposition:contentDisposition
                             mimeType:mimeType
                          originalURL:originalURL
                        destinationPath:destinationPath
                         receivedBytes:receivedBytes
                            totalBytes:totalBytes
                         hasTotalBytes:hasTotalBytes
                          isInProgress:isInProgress
                            isComplete:isComplete
                            isCanceled:isCanceled
                         isInterrupted:isInterrupted];
}

- (void)browserDidRequestPopup:(NSString *)url {
  if (_closed || _closeRequested || _ordinaryCloseRequested || url.length == 0) {
    return;
  }
  // Deliberately no logging here: a popup URL can carry an OAuth code. The
  // runtime owner reports the sanitized form.
  [self.delegate browserBridge:self didRequestNewTabWithURL:url];
}

- (BOOL)browserRequestsFocusFromSystem:(BOOL)fromSystem {
  // A closed or closing browser never takes the keyboard; the delegate decides
  // for a live one, because only it knows whether this surface is still the
  // visible selected one (Milestone 3 focus fix).
  if (_closed || _closeRequested || _ordinaryCloseRequested) {
    return NO;
  }
  // A page navigation or window activation must not steal the keyboard from
  // the docked console. Explicit page-focus commands release inspector focus.
  NSView *inspectorParent = _devToolsParentView;
  if (NBResponderBelongsToView(inspectorParent.window.firstResponder, inspectorParent)) {
    return NO;
  }
  return [self.delegate browserBridge:self allowsFocusRequestFromSystem:fromSystem];
}

- (void)browserDidAcceptClose {
  if (_closed || _closeCommitted || !_ordinaryCloseRequested) {
    return;
  }
  _ordinaryCloseRequested = NO;
  _closeCommitted = YES;
  _closeRequested = YES;
  [self.delegate browserBridgeDidAcceptClose:self];
  NBShutdownTimingMark(@"ordinary-close-accepted");
  // The embedded child view has no top-level window whose close notification
  // can finish CEF's non-forced CloseBrowser(false) sequence. Acceptance is
  // delivered asynchronously after DoClose has unwound, so it is now safe to
  // force the final host teardown without bypassing beforeunload.
  if (CefRefPtr<CefBrowser> browser = _client->browser()) {
    NBShutdownTimingMark(@"ordinary-close-force");
    browser->GetHost()->CloseBrowser(/*force_close=*/true);
  } else {
    NBShutdownTimingMark(@"ordinary-close-no-browser");
  }
}

- (void)browserDidCancelClose {
  if (_closed || _closeRequested || !_ordinaryCloseRequested) {
    return;
  }
  _ordinaryCloseRequested = NO;
  [self.delegate browserBridgeDidCancelClose:self];
}

- (void)browserDidRequestBeforeUnloadDialog:(NSString *)message {
  if (_closed || _closeRequested || !_ordinaryCloseRequested) {
    _client->ContinueBeforeUnload(false);
    return;
  }
  if (_beforeUnloadAlert != nil) {
    return;
  }

  NSWindow *window = _parentView.window;
  if (window == nil) {
    _client->ContinueBeforeUnload(false);
    [self browserDidCancelClose];
    return;
  }

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Leave this page?";
  alert.informativeText = message.length > 0
      ? message
      : @"Any unsaved changes may be lost.";
  [alert addButtonWithTitle:@"Stay"];
  [alert addButtonWithTitle:@"Leave"];
  _beforeUnloadAlert = alert;

  __weak BrowserBridge *weakSelf = self;
  [alert beginSheetModalForWindow:window
                completionHandler:^(NSModalResponse response) {
    BrowserBridge *strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_beforeUnloadAlert != alert) {
      return;
    }
    strongSelf->_beforeUnloadAlert = nil;
    const BOOL accept = response == NSAlertSecondButtonReturn;
    // Continue() is the source of truth for CEF's beforeunload result. Only
    // after delivering that explicit result do we notify BrowserSession, which
    // commits an accepted close exactly once or returns to open on cancel.
    strongSelf->_client->ContinueBeforeUnload(accept);
    if (accept) {
      [strongSelf browserDidAcceptClose];
    } else {
      [strongSelf browserDidCancelClose];
    }
  }];

  // The integration driver still presents the real native sheet, but supplies
  // an explicit button choice through the environment so both result branches
  // can run unattended. This is test input, never production close logic.
  NSString *automatedResponse =
      NSProcessInfo.processInfo.environment[@"NATIVEBROWSER_BEFOREUNLOAD_AUTORESPONSE"];
  BOOL hasAutomatedResponse = [automatedResponse isEqualToString:@"cancel"] ||
      [automatedResponse isEqualToString:@"accept"];
  if (hasAutomatedResponse) {
    const BOOL accept = [automatedResponse isEqualToString:@"accept"];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSButton *button = alert.buttons[accept ? 1 : 0];
      [button performClick:nil];
    });
  }
}

- (void)browserDidResetBeforeUnloadDialog {
  NSAlert *alert = _beforeUnloadAlert;
  _beforeUnloadAlert = nil;
  if (alert != nil && alert.window.sheetParent != nil) {
    [alert.window.sheetParent endSheet:alert.window
                            returnCode:NSModalResponseCancel];
  }
  if (!_closed && !_closeRequested && _ordinaryCloseRequested) {
    [self browserDidCancelClose];
  }
}

- (void)dismissBeforeUnloadDialogForApplicationTermination {
  NSAlert *alert = _beforeUnloadAlert;
  _beforeUnloadAlert = nil;
  if (alert == nil) {
    return;
  }
  // The termination path is intentionally independent of the user-close
  // state machine. Resolve the CEF callback as stay, dismiss the native sheet,
  // and then let CloseBrowser(force_close=true) finish teardown.
  _client->ContinueBeforeUnload(false);
  if (alert.window.sheetParent != nil) {
    [alert.window.sheetParent endSheet:alert.window
                            returnCode:NSModalResponseCancel];
  } else {
    [alert.window orderOut:nil];
  }
}

- (void)browserDidTerminateRendererWithStatus:(NSInteger)status
                                     errorCode:(NSInteger)errorCode {
  if (_closed) {
    return;
  }
  [self.delegate browserBridge:self
      didTerminateRendererWithStatus:status
                           errorCode:errorCode];
}

- (void)browserDidClose {
  if (_closed) {
    return;
  }
  if (_ordinaryCloseRequested) {
    // A view hierarchy teardown can bypass DoClose. Once OnBeforeClose is
    // observed the close is necessarily accepted, so do not leave the domain
    // tab behind waiting for a callback that CEF will never send.
    [self browserDidAcceptClose];
  }
  _closed = YES;
  [self closeDevTools];
  // Keep the session and native hosts alive until BOTH OnBeforeClose callbacks
  // arrive. Otherwise the manager could shut CEF down with a live inspector.
  [self notifyCloseWhenAllBrowsersAreClosed];
}

@end
