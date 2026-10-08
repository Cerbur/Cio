#import "BrowserBridge.h"

NS_ASSUME_NONNULL_BEGIN

// Backend callbacks stay private to the CEF implementation.
@interface BrowserBridge (CEFEvents)

// MARK: - Events from the CEF layer
//
// Called by CEFClientHandler when Chromium reports something. Not part of the
// Swift-facing API.

- (void)browserDidCreate;
- (void)completeClose;
- (void)browserDidUpdateTitle:(NSString *)title;
- (void)browserDidUpdateFaviconURLs:(NSArray<NSString *> *)urls;
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
- (void)browserDidRequestBeforeUnloadDialog:(NSString *)message;
- (void)browserDidResetBeforeUnloadDialog;
- (void)browserDidTerminateRendererWithStatus:(NSInteger)status
                                     errorCode:(NSInteger)errorCode;
- (void)browserDidClose;
- (void)devToolsDidCreate;
- (void)browserDidRequestInspectNode:(NSInteger)backendNodeID;
- (void)devToolsDidClose;
- (BOOL)devToolsAllowsFocus;
- (nullable NSView *)devToolsEmulationHostView;

@end

NS_ASSUME_NONNULL_END
