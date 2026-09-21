//
//  BrowserBridge.h
//  NativeBrowser
//
//  Objective-C boundary around a single Chromium browser instance
//  (ARCHITECTURE.md section 8).
//
//  This is the only interface Swift sees for browser content. CEF C++ types
//  (CefBrowser, CefClient, CefFrame, CefBrowserHost, ...) never appear here.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class BrowserBridge;

/// Events produced by a Chromium browser instance.
///
/// Every method is called on the main thread: the Objective-C++ side marshals
/// CEF callbacks before delivering them, so implementations may touch AppKit
/// and SwiftUI state directly.
NS_SWIFT_UI_ACTOR
@protocol BrowserBridgeDelegate <NSObject>

/// The Chromium browser object now exists and accepts commands.
- (void)browserBridgeDidCreateBrowser:(BrowserBridge *)bridge;
- (void)browserBridge:(BrowserBridge *)bridge didUpdateTitle:(NSString *)title;
- (void)browserBridge:(BrowserBridge *)bridge didUpdateURL:(NSString *)url;
- (void)browserBridge:(BrowserBridge *)bridge
    didUpdateLoadingState:(BOOL)isLoading
                canGoBack:(BOOL)canGoBack
             canGoForward:(BOOL)canGoForward;
- (void)browserBridge:(BrowserBridge *)bridge
    didUpdateLoadingProgress:(double)progress;
- (void)browserBridge:(BrowserBridge *)bridge
    didFailLoadWithError:(NSString *)errorText
               errorCode:(NSInteger)errorCode
               failedURL:(NSString *)failedURL;

/// A top-level frame completed successfully. The URL comes from the frame at
/// OnLoadEnd time, so redirects resolve to the final committed URL. This is
/// intentionally separate from didUpdateURL: address changes also include
/// provisional and failed navigations.
- (void)browserBridge:(BrowserBridge *)bridge
    didFinishMainFrameLoadWithURL:(NSString *)url;

/// Returns the destination selected by the application-level DownloadManager.
/// The value is a full path, not a user-visible URL.
- (NSString *)browserBridge:(BrowserBridge *)bridge
    destinationPathForDownloadIdentifier:(NSInteger)downloadIdentifier
                               sourceURL:(NSString *)sourceURL
                         suggestedFileName:(NSString *)suggestedFileName
                      cefSuggestedFileName:(NSString *)cefSuggestedFileName
                       contentDisposition:(NSString *)contentDisposition
                               mimeType:(NSString *)mimeType
                            originalURL:(NSString *)originalURL;

/// A typed download progress/status update translated from CEF. Empty strings
/// mean that CEF has not supplied a path yet; no CEF object crosses this API.
- (void)browserBridge:(BrowserBridge *)bridge
    didUpdateDownloadWithIdentifier:(NSInteger)downloadIdentifier
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
                       isInterrupted:(BOOL)isInterrupted;

/// Chromium requested a popup (`target=_blank`, `window.open`).
///
/// The unmanaged native CEF window has already been cancelled; `url` is the
/// target the runtime owner should open as a managed tab instead (Milestone 3
/// section 26). The URL is NOT logged here: it routinely carries an OAuth code
/// or a signature, and the owner reports it through URLLogSanitizer.
- (void)browserBridge:(BrowserBridge *)bridge didRequestNewTabWithURL:(NSString *)url;

/// Chromium is asking for the keyboard (`CefFocusHandler::OnSetFocus`).
///
/// Chromium asks when a browser component starts navigating, which happens
/// asynchronously - after the tab may already have been hidden and after the
/// application decided whether that page should own the keyboard. `fromSystem`
/// is YES when the request originates outside Chromium (window activation),
/// NO for Chromium's own navigation-time request. Return YES to let Chromium
/// move the keyboard, NO to cancel the focus change.
///
/// This is the second half of the Milestone 3 focus invariant: gating the
/// application's own -setFocus: is not enough, because a new browser focuses
/// itself when its first navigation starts.
- (BOOL)browserBridge:(BrowserBridge *)bridge
    allowsFocusRequestFromSystem:(BOOL)fromSystem;

- (void)browserBridgeDidAcceptClose:(BrowserBridge *)bridge;
- (void)browserBridgeDidCancelClose:(BrowserBridge *)bridge;
- (void)browserBridge:(BrowserBridge *)bridge
    didTerminateRendererWithStatus:(NSInteger)status
                         errorCode:(NSInteger)errorCode;

- (void)browserBridgeDidClose:(BrowserBridge *)bridge;

@end

/// Owns one Chromium browser and renders it into an NSView provided by the
/// caller.
NS_SWIFT_UI_ACTOR
@interface BrowserBridge : NSObject

@property(nonatomic, weak, nullable) id<BrowserBridgeDelegate> delegate;

/// YES when the underlying Chromium browser no longer exists, i.e. after
/// CefLifeSpanHandler::OnBeforeClose. A closed bridge cannot be reused.
@property(nonatomic, readonly, getter=isClosed) BOOL closed;

/// Chromium's identifier for the browser this bridge owns, or -1 before the
/// browser exists. Two live bridges must never report the same value.
@property(nonatomic, readonly) int browserIdentifier;

/// Creates a bridge that renders into `view`. The Chromium browser itself is
/// created by the first -loadURL: call, because the parent view must be in a
/// window before the browser view can be attached.
- (instancetype)initWithParentView:(NSView *)view NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Loads `url`, creating the Chromium browser if this is the first call.
- (void)loadURL:(NSString *)url;

- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;

/// Starts a download through the browser's real CEF download pipeline. The
/// verification harness uses this to avoid making download correctness depend
/// on the fixture page's DOM or synthetic input dispatch.
- (void)startDownloadURL:(NSString *)url;

/// Gives keyboard focus to the page, or releases it.
- (void)setFocus:(BOOL)focused;

/// Tells the browser that its view size changed.
- (void)resizeToBounds:(NSRect)bounds;

/// Moves the browser view into another container view. Used when SwiftUI
/// re-creates the representable's NSView.
- (void)reparentToView:(NSView *)view;

/// Requests browser destruction. -browserBridgeDidClose: is delivered once
/// Chromium has finished tearing the browser down.
///
/// `applicationTerminating` additionally releases the window's first responder
/// unconditionally while the browser view is detached. That unconditional
/// release is the Milestone 2 Cmd+Q fix and stays correct while the whole
/// application is quitting. It must NOT run for an ordinary background-tab
/// close: with several browsers in one window it would take the keyboard away
/// from the active tab or from the native address field (Milestone 3 section
/// 17). Either way the closed browser always releases its own CEF focus, and the
/// window's first responder is cleared when it belonged to the view being
/// destroyed.
- (void)closeForApplicationTermination:(BOOL)applicationTerminating;

/// Releases the Chromium view, which is what actually destroys the browser.
///
/// Normally reached through CefLifeSpanHandler::DoClose. Exposed because DoClose
/// is not always delivered - a real Cmd+Q that Chromium dispatched itself was
/// observed to lose the close while the run loop stayed healthy - so the
/// termination path can complete the release instead of waiting. Idempotent.
- (void)releaseBrowserView;

// MARK: - Events from the CEF layer
//
// Called by CEFClientHandler when Chromium reports something. Not part of the
// Swift-facing API.

- (void)browserDidCreate;
- (void)completeClose;
- (void)browserDidUpdateTitle:(NSString *)title;
- (void)browserDidUpdateURL:(NSString *)url;
- (void)browserDidUpdateLoadingState:(BOOL)isLoading
                           canGoBack:(BOOL)canGoBack
                        canGoForward:(BOOL)canGoForward;
- (void)browserDidUpdateLoadingProgress:(double)progress;
- (void)browserDidFailLoadWithError:(NSString *)errorText
                          errorCode:(NSInteger)errorCode
                          failedURL:(NSString *)failedURL;
- (void)browserDidFinishMainFrameLoadWithURL:(NSString *)url;
- (NSString *)downloadDestinationPathForIdentifier:(NSInteger)downloadIdentifier
                                          sourceURL:(NSString *)sourceURL
                                    suggestedFileName:(NSString *)suggestedFileName
                                 cefSuggestedFileName:(NSString *)cefSuggestedFileName
                                  contentDisposition:(NSString *)contentDisposition
                                          mimeType:(NSString *)mimeType
                                       originalURL:(NSString *)originalURL;
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
                                   isInterrupted:(BOOL)isInterrupted;
- (void)browserDidRequestPopup:(NSString *)url;
/// CefFocusHandler::OnSetFocus: Chromium is requesting keyboard focus. Answered
/// by the delegate; a closing or closed bridge never allows it.
- (BOOL)browserRequestsFocusFromSystem:(BOOL)fromSystem;
- (void)browserDidAcceptClose;
- (void)browserDidCancelClose;
- (void)browserDidCloseBeforeUnloadDialog;
- (void)browserDidTerminateRendererWithStatus:(NSInteger)status
                                     errorCode:(NSInteger)errorCode;
- (void)browserDidClose;

@end

NS_ASSUME_NONNULL_END
