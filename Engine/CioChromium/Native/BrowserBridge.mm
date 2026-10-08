#import "chrome/browser/ui/cio/BrowserBridge.h"
#include "chrome/browser/ui/cio/CioWindowHooks.h"

#include <map>
#include <deque>
#include <memory>
#include "base/memory/raw_ptr.h"
#include "base/logging.h"
#include "content/public/browser/ssl_status.h"
#include "third_party/blink/public/mojom/frame/user_activation_notification_type.mojom.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/download_manager.h"
#include "net/cert/cert_status_flags.h"
#include "net/cert/x509_certificate.h"
#include "net/cert/x509_util.h"
#include "net/base/net_errors.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "content/public/browser/download_item_utils.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "base/files/file_path.h"
#include "net/base/filename_util.h"
#include "ui/base/page_transition_types.h"
#include "third_party/blink/public/mojom/favicon/favicon_url.mojom.h"
#include "url/gurl.h"

@interface BrowserConnectionInfo ()
@property(nonatomic, readwrite, copy) NSString *url;
@property(nonatomic, readwrite) BOOL usesTLS;
@property(nonatomic, readwrite) BOOL certificateValid;
@property(nonatomic, readwrite) BOOL hasInsecureContent;
@property(nonatomic, readwrite, copy) NSArray<NSData *> *certificateChain;
@end
@implementation BrowserConnectionInfo
@synthesize url = _url, usesTLS = _usesTLS, certificateValid = _certificateValid,
    hasInsecureContent = _hasInsecureContent, certificateChain = _certificateChain;
@end

@interface BrowserBridge (NativeEvents)
- (void)nativeLoadingChanged;
- (void)nativeTitleChanged;
- (void)nativeNavigationFinished:(content::NavigationHandle *)handle;
- (void)nativePageLoaded:(NSString *)url;
- (void)nativeClosed;
- (void)nativeAcceptClose;
- (void)nativeCancelClose;
- (void)nativeRendererGone:(NSInteger)status;
- (BOOL)nativeCanFocus;
- (void)nativeRefreshDevTools;
- (void)nativeDevToolsClosed;
- (content::WebContents*)nativeContents;
@end

namespace {
__weak NSView* gCreatingHost;
__weak NSWindow* gWindow;
int gNextIdentifier = 1;
std::map<std::string, std::deque<std::unique_ptr<content::WebContents>>>& PendingPopups() {
  static auto* pending = new std::map<std::string, std::deque<std::unique_ptr<content::WebContents>>>;
  return *pending;
}
std::map<Browser*, __weak BrowserBridge*>& Browsers() {
  static auto* browsers = new std::map<Browser*, __weak BrowserBridge*>;
  return *browsers;
}
class PageObserver final : public content::WebContentsObserver {
 public:
  PageObserver(content::WebContents* contents, BrowserBridge* bridge,
               bool devtools = false)
      : WebContentsObserver(contents), bridge_(bridge), devtools_(devtools) {}
  void DidStartLoading() override { if (!devtools_) [bridge_ nativeLoadingChanged]; }
  void DidStopLoading() override { if (!devtools_) [bridge_ nativeLoadingChanged]; }
  void LoadProgressChanged(double progress) override {
    if (devtools_) return;
    auto* bridge = bridge_;
    [bridge.delegate browserBridge:bridge didUpdateLoadingProgress:progress];
  }
  void TitleWasSet(content::NavigationEntry*) override {
    if (!devtools_) [bridge_ nativeTitleChanged];
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (!devtools_ && handle->IsInPrimaryMainFrame()) [bridge_ nativeNavigationFinished:handle];
  }
  void DidFinishLoad(content::RenderFrameHost* frame, const GURL& url) override {
    if (!devtools_ && frame == web_contents()->GetPrimaryMainFrame())
      [bridge_ nativePageLoaded:base::SysUTF8ToNSString(url.spec())];
  }
  void DidUpdateFaviconURL(content::RenderFrameHost*,
      const std::vector<blink::mojom::FaviconURLPtr>& icons,
      blink::mojom::FaviconUpdateReason) override {
    if (devtools_) return;
    NSMutableArray* urls = [NSMutableArray array];
    for (auto& icon : icons) [urls addObject:base::SysUTF8ToNSString(icon->icon_url.spec())];
    auto* bridge = bridge_;
    [bridge.delegate browserBridge:bridge didUpdateFaviconURLs:urls];
  }
  void BeforeUnloadFired(bool proceed) override {
    if (devtools_) return;
    if (proceed) [bridge_ nativeAcceptClose];
    else [bridge_ nativeCancelClose];
  }
  void BeforeUnloadDialogCancelled() override { if (!devtools_) [bridge_ nativeCancelClose]; }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus status) override {
    if (!devtools_) [bridge_ nativeRendererGone:static_cast<NSInteger>(status)];
  }
  void WebContentsDestroyed() override {
    if (!devtools_) cio::HideHungRenderer(web_contents());
    Observe(nullptr);
    if (devtools_) [bridge_ nativeDevToolsClosed];
    else [bridge_ nativeClosed];
  }
 private:
  __weak BrowserBridge* bridge_;
  bool devtools_;
};
}

@implementation BrowserBridge {
  __weak NSView* _parent;
  __weak NSView* _devtoolsParent;
  __weak NSView* _emulationParent;
  NSView* _pageView;
  NSView* _devtoolsView;
  raw_ptr<Browser> _browser;
  raw_ptr<content::WebContents> _contents;
  raw_ptr<content::WebContents> _devtools;
  std::unique_ptr<PageObserver> _observer;
  std::unique_ptr<PageObserver> _devtoolsObserver;
  int _identifier;
  BOOL _closed;
  BOOL _closing;
  BOOL _accepted;
  BOOL _terminationRequested;
  BOOL _devtoolsRequested;
  BOOL _devtoolsClosing;
}
@synthesize delegate = _delegate;
- (instancetype)initWithParentView:(NSView *)view {
  if ((self = [super init])) { _parent = view; _identifier = -1; }
  return self;
}
- (BOOL)isClosed { return _closed; }
- (int)browserIdentifier { return _identifier; }
- (void)loadURL:(NSString *)url {
  if (_closed || _closing || !url.length) return;
  BOOL adopted = NO;
  if (!_browser) {
    Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
    if (!profile || !_parent.window) return;
    cio::SetCreatingHostView(_parent);
    Browser::CreateParams params(profile, false);
    params.omit_from_session_restore = true;
    params.should_trigger_session_restore = false;
    _browser = Browser::Create(params);
    cio::SetCreatingHostView(nil);
    Browsers()[_browser] = self;
    auto pending = PendingPopups().find(base::SysNSStringToUTF8(url));
    if (pending != PendingPopups().end() && !pending->second.empty()) {
      auto contents = std::move(pending->second.front());
      pending->second.pop_front();
      if (pending->second.empty()) PendingPopups().erase(pending);
      _browser->tab_strip_model()->AppendWebContents(std::move(contents), true);
      adopted = YES;
    } else {
      chrome::AddTabAt(_browser, GURL("about:blank"), -1, true);
    }
    _contents = _browser->tab_strip_model()->GetActiveWebContents();
    _observer = std::make_unique<PageObserver>(_contents, self);
    _identifier = gNextIdentifier++;
    _pageView = _contents->GetNativeView().GetNativeNSView();
    _pageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self reparentToView:_parent];
    [self.delegate browserBridgeDidCreateBrowser:self];
  }
  if (adopted) {
    [self.delegate browserBridge:self didUpdateURL:url];
    [self nativeLoadingChanged]; [self nativeTitleChanged];
    return;
  }
  content::NavigationController::LoadURLParams params(GURL(base::SysNSStringToUTF8(url)));
  params.transition_type = ui::PAGE_TRANSITION_TYPED;
  _contents->GetController().LoadURLWithParams(params);
}
- (void)goBack { if (_contents && _contents->GetController().CanGoBack()) _contents->GetController().GoBack(); }
- (void)goForward { if (_contents && _contents->GetController().CanGoForward()) _contents->GetController().GoForward(); }
- (void)reload { if (_contents) _contents->GetController().Reload(content::ReloadType::NORMAL, false); }
- (void)stopLoading { if (_contents) _contents->Stop(); }
- (void)viewPageSource {
  if (_contents) [self.delegate browserBridge:self didRequestNewTabWithURL:
      [@"view-source:" stringByAppendingString:base::SysUTF8ToNSString(_contents->GetLastCommittedURL().spec())]];
}
- (BOOL)nativeCanFocus {
  return !_closed && !_closing && _parent.window && !_parent.isHiddenOrHasHiddenAncestor &&
      [self.delegate browserBridge:self allowsFocusRequestFromSystem:NO];
}
- (void)setFocus:(BOOL)focused {
  if (!_contents) return;
  if (focused && [self nativeCanFocus]) _contents->Focus();
  else if (!focused) {
    if (auto* widget = _contents->GetRenderWidgetHostView())
      widget->GetRenderWidgetHost()->Blur();
    NSResponder* responder = _parent.window.firstResponder;
    if ([responder isKindOfClass:NSView.class] && [(NSView*)responder isDescendantOf:_pageView]) {
      // NSTextField reports becoming focused before AppKit installs its field
      // editor. Clearing the old page responder synchronously cancels that
      // handoff. Only clear it if it still owns focus after the handoff returns.
      __weak NSWindow* window = _parent.window;
      __weak NSResponder* previous = responder;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (previous && window.firstResponder == previous) [window makeFirstResponder:nil];
      });
    }
  }
}
- (BOOL)setDarkAppearance:(BOOL)dark {
  if (!_contents) return NO;
  _pageView.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
  _contents->OnWebPreferencesChanged();
  return YES;
}
- (void)resizeToBounds:(NSRect)bounds {
  if (!_contents) return;
  _pageView.frame = NSMakeRect(0, 0, bounds.size.width, bounds.size.height);
  auto* widget = _contents->GetRenderWidgetHostView();
  if (widget) widget->SetSize(gfx::Size(bounds.size.width, bounds.size.height));
}
- (void)reparentToView:(NSView *)view {
  if (_closed) return;
  _parent = view;
  if (view.window) gWindow = view.window;
  if (_pageView && _pageView.superview != view) { [_pageView removeFromSuperview]; [view addSubview:_pageView]; }
  [self resizeToBounds:view.bounds];
  if (_contents) {
    if (view.isHiddenOrHasHiddenAncestor) _contents->WasHidden();
    else _contents->WasShown();
  }
}
- (void)closeForApplicationTermination:(BOOL)applicationTerminating {
  if (_closed || (_closing && !applicationTerminating)) return;
  _terminationRequested = applicationTerminating;
  _closing = YES;
  if (applicationTerminating && _browser) {
    // Preserve Cio's existing termination policy. Ordinary tab closes still
    // use the normal Chromium beforeunload confirmation and veto.
    UnloadController::From(_browser)->set_force_skip_warning_user_on_close(true);
    auto* dialogs = _contents->GetDelegate()->GetJavaScriptDialogManager(_contents);
    if (dialogs) dialogs->CancelDialogs(_contents, false);
  }
  [self setFocus:NO];
  [self closeDevTools];
  if (_browser) BrowserWindow::FromBrowser(_browser)->Close();
  else [self nativeClosed];
}
- (void)releaseBrowserView {
  // The runtime's teardown fallback may only finish an already accepted close.
  if (_accepted && _browser) BrowserWindow::FromBrowser(_browser)->Close();
}
- (void)nativeAcceptClose {
  if (!_closing || _accepted) return;
  _accepted = YES;
  [self.delegate browserBridgeDidAcceptClose:self];
}
- (void)nativeCancelClose {
  if (!_closing || _closed || _terminationRequested) return;
  _closing = NO; _accepted = NO;
  [self.delegate browserBridgeDidCancelClose:self];
}
- (void)nativeClosed {
  if (_closed) return;
  _closing = YES;
  [self nativeAcceptClose];
  _closed = YES;
  _contents = nullptr;
  if (_browser) Browsers().erase(_browser);
  _browser = nullptr;
  [_pageView removeFromSuperview]; _pageView = nil;
  // Leave Chromium's destruction stack before Swift releases the session.
  dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate browserBridgeDidClose:self]; });
}
- (void)nativeLoadingChanged {
  if (!_contents) return;
  auto& controller = _contents->GetController();
  [self.delegate browserBridge:self didUpdateLoadingState:_contents->IsLoading()
      canGoBack:controller.CanGoBack() canGoForward:controller.CanGoForward()];
}
- (void)nativeTitleChanged {
  if (_contents) [self.delegate browserBridge:self didUpdateTitle:base::SysUTF16ToNSString(_contents->GetTitle())];
}
- (void)nativeNavigationFinished:(content::NavigationHandle *)handle {
  if (handle->HasCommitted()) {
    [self.delegate browserBridge:self didUpdateURL:base::SysUTF8ToNSString(handle->GetURL().spec())];
    // A restored history entry may already have its title without emitting
    // TitleWasSet again (for example when restored from the back-forward cache).
    [self nativeTitleChanged];
  }
  if (handle->GetNetErrorCode() && handle->GetNetErrorCode() != net::ERR_ABORTED) [self.delegate browserBridge:self
      didFailLoadWithError:base::SysUTF8ToNSString(net::ErrorToString(handle->GetNetErrorCode()))
      errorCode:handle->GetNetErrorCode() failedURL:base::SysUTF8ToNSString(handle->GetURL().spec())];
  [self nativeLoadingChanged];
}
- (void)nativePageLoaded:(NSString *)url { [self.delegate browserBridge:self didFinishMainFrameLoadWithURL:url]; }
- (void)nativeRendererGone:(NSInteger)status { [self.delegate browserBridge:self didTerminateRendererWithStatus:status errorCode:0]; }
- (BrowserConnectionInfo *)connectionInfo {
  if (!_contents) return nil;
  auto* entry = _contents->GetController().GetVisibleEntry();
  if (!entry) return nil;
  BrowserConnectionInfo* info = [[BrowserConnectionInfo alloc] init];
  info.url = base::SysUTF8ToNSString(entry->GetURL().spec());
  const auto& ssl = entry->GetSSL();
  info.usesTLS = entry->GetURL().SchemeIsCryptographic();
  info.certificateValid = ssl.certificate && !net::IsCertStatusError(ssl.cert_status);
  info.hasInsecureContent = ssl.content_status != 0;
  NSMutableArray* chain = [NSMutableArray array];
  if (ssl.certificate) for (const auto& buffer : ssl.certificate->cert_buffers()) {
    auto bytes = net::x509_util::CryptoBufferAsSpan(buffer.get());
    [chain addObject:[NSData dataWithBytes:bytes.data() length:bytes.size()]];
  }
  info.certificateChain = chain;
  return info;
}
- (void)startDownloadURL:(NSString *)url {
  if (!_contents) return;
  constexpr auto annotation = net::DefineNetworkTrafficAnnotation("cio_user_download", R"(
    semantics {
      sender: "Cio user requested download"
      description: "Downloads a URL explicitly selected by the user."
      trigger: "User chooses to download a link."
      data: "The URL and the current profile's cookies."
      destination: WEBSITE
    }
    policy {
      cookies_allowed: YES
      cookies_store: "Chromium profile"
      setting: "Only performed following a user download action."
      policy_exception_justification: "User initiated network operation."
    })");
  auto parameters = _contents->GetPrimaryMainFrame()->CreateDownloadUrlParameters(
      GURL(base::SysNSStringToUTF8(url)), annotation);
  _browser->GetProfile()->GetDownloadManager()->DownloadUrl(std::move(parameters));
}
- (void)sendTestUserActivation {
  if (_contents) _contents->GetPrimaryMainFrame()->NotifyUserActivation(
      blink::mojom::UserActivationNotificationType::kInteraction);
}
- (BOOL)showDevToolsInView:(NSView *)view {
  if (!_contents || _closing) return NO;
  _devtoolsParent = view; _devtoolsRequested = YES;
  _devtoolsClosing = NO;
  DevToolsWindow::OpenDevToolsWindow(_contents, DevToolsOpenedByAction::kMainMenuOrMainShortcut);
  [self nativeRefreshDevTools];
  return YES;
}
- (void)nativeRefreshDevTools {
  if (!_contents) return;
  const bool hidden = !_parent.window || _parent.isHiddenOrHasHiddenAncestor;
  if (hidden && _contents->GetVisibility() == content::Visibility::VISIBLE) _contents->WasHidden();
  else if (!hidden && _contents->GetVisibility() == content::Visibility::HIDDEN) _contents->WasShown();
  if (_devtoolsClosing || _closing) return;
  DevToolsContentsResizingStrategy strategy;
  auto* contents = DevToolsWindow::GetInTabWebContents(_contents, &strategy);
  if (!contents) return;
  auto bounds = strategy.bounds();
  if (_emulationParent && !bounds.IsEmpty()) {
    [self.delegate browserBridge:self didSetInspectedPageBounds:NSMakeRect(
        bounds.x(), _emulationParent.bounds.size.height - bounds.bottom(), bounds.width(), bounds.height())];
  }
  if (contents == _devtools) return;
  _devtoolsRequested = YES;
  _devtools = contents;
  _devtoolsObserver = std::make_unique<PageObserver>(contents, self, true);
  _devtoolsView = contents->GetNativeView().GetNativeNSView();
  _devtoolsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.delegate browserBridge:self didSetDevToolsDocked:YES];
  [self reparentDevToolsToView:_devtoolsParent];
}
- (content::WebContents*)nativeContents { return _contents.get(); }
- (void)nativeDevToolsClosed {
  _devtools = nullptr; _devtoolsRequested = NO;
  _devtoolsClosing = NO;
  [_devtoolsView removeFromSuperview]; _devtoolsView = nil;
  dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate browserBridgeDidCloseDevTools:self]; });
}
- (void)resizeDevTools { if (_devtools) _devtoolsView.frame = _devtoolsParent.bounds; }
- (void)reparentDevToolsToView:(NSView *)view {
  if (!view) return;
  _devtoolsParent = view;
  if (_devtoolsView && _devtoolsView.superview != view) { [_devtoolsView removeFromSuperview]; [view addSubview:_devtoolsView]; }
  [self resizeDevTools];
}
- (void)setDevToolsEmulationHostView:(NSView *)view { _emulationParent = view; }
- (void)closeDevTools {
  _devtoolsRequested = NO;
  _devtoolsClosing = _devtools != nullptr;
  if (_devtools) _devtools->ClosePage();
  _devtools = nullptr;
  [_devtoolsView removeFromSuperview]; _devtoolsView = nil;
}
- (void)revealDevToolsNode:(NSInteger)node {
  if (!_devtools) return;
  NSString* script = [NSString stringWithFormat:
      @"DevToolsAPI.dispatchMessage(JSON.stringify({method:'Overlay.inspectNodeRequested',params:{backendNodeId:%ld}}))", (long)node];
  _devtools->GetPrimaryMainFrame()->ExecuteJavaScript(base::SysNSStringToUTF16(script), base::NullCallback());
}
@end

namespace cio {
void SetCreatingHostView(NSView* view) { gCreatingHost = view; if (view.window) gWindow = view.window; }
NSWindow* CioMainWindow() { return gWindow ?: NSApp.mainWindow; }
Browser* CioBrowser() { return Browsers().empty() ? nullptr : Browsers().begin()->first; }
void OnBrowserWindowCreated(Browser*) {}
void OnBrowserWindowDestroyed(Browser* browser) { Browsers().erase(browser); }
void EnsureCioUIStarted(Browser*) {}
void RefreshDevTools() {
  for (auto& [browser, bridge] : Browsers()) [bridge nativeRefreshDevTools];
}
bool CanFocusBrowser(Browser* browser) {
  auto found = Browsers().find(browser);
  return found != Browsers().end() && [found->second nativeCanFocus];
}
}
namespace {
BrowserBridge* BridgeForContents(content::WebContents* contents) {
  if (!contents) return nil;
  for (auto& [browser, bridge] : Browsers())
    if ([bridge nativeContents] == contents) return bridge;
  return nil;
}
class DownloadObserver final : public download::DownloadItem::Observer {
 public:
  DownloadObserver(download::DownloadItem* item, BrowserBridge* bridge)
      : item_(item), bridge_(bridge) { item_->AddObserver(this); }
  ~DownloadObserver() override { if (item_) item_->RemoveObserver(this); }
  void OnDownloadUpdated(download::DownloadItem* item) override {
    BrowserBridge* bridge = bridge_;
    if (!bridge) return;
    if (item->GetState() == download::DownloadItem::INTERRUPTED)
      LOG(ERROR) << "Cio download interrupted: "
                 << download::DownloadInterruptReasonToString(item->GetLastReason());
    [bridge.delegate browserBridge:bridge didUpdateDownloadWithIdentifier:item->GetId()
        sourceURL:base::SysUTF8ToNSString(item->GetURL().spec())
        suggestedFileName:base::SysUTF8ToNSString(item->GetFileNameToReportUser().value())
        cefSuggestedFileName:base::SysUTF8ToNSString(item->GetSuggestedFilename())
        contentDisposition:base::SysUTF8ToNSString(item->GetContentDisposition())
        mimeType:base::SysUTF8ToNSString(item->GetMimeType())
        originalURL:base::SysUTF8ToNSString(item->GetOriginalUrl().spec())
        destinationPath:base::SysUTF8ToNSString(item->GetTargetFilePath().value())
        receivedBytes:item->GetReceivedBytes() totalBytes:item->GetTotalBytes()
        hasTotalBytes:item->GetTotalBytes() > 0
        isInProgress:item->GetState() == download::DownloadItem::IN_PROGRESS
        isComplete:item->GetState() == download::DownloadItem::COMPLETE
        isCanceled:item->GetState() == download::DownloadItem::CANCELLED
        isInterrupted:item->GetState() == download::DownloadItem::INTERRUPTED];
  }
  void OnDownloadDestroyed(download::DownloadItem*) override { item_ = nullptr; }
 private:
  raw_ptr<download::DownloadItem> item_;
  __weak BrowserBridge* bridge_;
};
std::map<uint32_t, std::unique_ptr<DownloadObserver>>& Downloads() {
  static auto* downloads = new std::map<uint32_t, std::unique_ptr<DownloadObserver>>;
  return *downloads;
}
}
namespace cio {
base::FilePath DownloadPath(download::DownloadItem* item) {
  BrowserBridge* bridge = BridgeForContents(content::DownloadItemUtils::GetOriginalWebContents(item));
  if (!bridge) return {};
  auto name = net::GenerateFileName(item->GetURL(), item->GetContentDisposition(),
      "UTF-8", item->GetSuggestedFilename(), item->GetMimeType(), "download");
  NSString* path = [bridge.delegate browserBridge:bridge destinationPathForDownloadIdentifier:item->GetId()
      sourceURL:base::SysUTF8ToNSString(item->GetURL().spec())
      suggestedFileName:base::SysUTF8ToNSString(name.value())
      cefSuggestedFileName:base::SysUTF8ToNSString(item->GetSuggestedFilename())
      contentDisposition:base::SysUTF8ToNSString(item->GetContentDisposition())
      mimeType:base::SysUTF8ToNSString(item->GetMimeType())
      originalURL:base::SysUTF8ToNSString(item->GetOriginalUrl().spec())];
  if (!Downloads().contains(item->GetId()))
    Downloads()[item->GetId()] = std::make_unique<DownloadObserver>(item, bridge);
  return base::FilePath(base::SysNSStringToUTF8(path ?: @""));
}
void ShutdownDownloads() { Downloads().clear(); PendingPopups().clear(); }
bool AdoptPopup(Browser* browser, std::unique_ptr<content::WebContents>& contents, const GURL& url) {
  if (!Browsers().contains(browser)) return false;
  contents->SetDelegate(nullptr);
  contents->WasHidden();
  const GURL target = url.is_valid() ? url : GURL("about:blank");
  PendingPopups()[target.spec()].push_back(std::move(contents));
  return OpenNewTab(browser, target);
}
bool OpenNewTab(Browser* browser, const GURL& url) {
  auto found = Browsers().find(browser);
  if (found == Browsers().end() || !url.is_valid()) return false;
  BrowserBridge* bridge = found->second;
  [bridge.delegate browserBridge:bridge didRequestNewTabWithURL:base::SysUTF8ToNSString(url.spec())];
  return true;
}
}
