//
//  CEFClientHandler.mm
//  NativeBrowser
//

#import "CEFClientHandler.h"

#import "BrowserBridge.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_download_item.h"
#include "include/cef_frame.h"

namespace {

/// Converts a CEF string to an NSString (empty string when it cannot be
/// converted).
NSString *NSStringFromCefString(const CefString &value) {
  const std::string utf8 = value.ToString();
  NSString *result = [NSString stringWithUTF8String:utf8.c_str()];
  return result != nil ? result : @"";
}

/// CEF callbacks arrive on the UI thread, which is the application's main
/// thread because the CEF message loop is pumped from the NSApplication run
/// loop. The hop is kept anyway so that AppKit is never touched from another
/// thread (ARCHITECTURE.md section 30).
void OnMainThread(void (^block)(void)) {
  if (NSThread.isMainThread) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

}  // namespace

CEFClientHandler::CEFClientHandler(BrowserBridge *bridge) : bridge_(bridge) {}

void CEFClientHandler::CancelActiveDownloads() {
  for (auto &entry : active_downloads_) {
    if (entry.second != nullptr) {
      entry.second->Cancel();
    }
  }
  active_downloads_.clear();
}

void CEFClientHandler::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                     const CefString &title) {
  NSString *value = NSStringFromCefString(title);
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidUpdateTitle:value];
  });
}

void CEFClientHandler::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString &url) {
  if (frame == nullptr || !frame->IsMain()) {
    return;
  }
  NSString *value = NSStringFromCefString(url);
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidUpdateURL:value];
  });
}

void CEFClientHandler::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                               double progress) {
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidUpdateLoadingProgress:progress];
  });
}

bool CEFClientHandler::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString &target_url,
    const CefString &target_frame_name,
    WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures &popupFeatures,
    CefWindowInfo &windowInfo,
    CefRefPtr<CefClient> &client,
    CefBrowserSettings &settings,
    CefRefPtr<CefDictionaryValue> &extra_info,
    bool *no_javascript_access) {
  // The unmanaged CEF popup is always cancelled: this application hosts its
  // browsers in its own view hierarchy, so a native CEF child window would not
  // be owned or closed by anything.
  //
  // The target URL is handed to the runtime owner instead, which opens it as a
  // managed tab (Milestone 3 section 26). It is deliberately not formatted into
  // any log here - a popup URL routinely carries an OAuth code or a signature,
  // and the owner reports it through URLLogSanitizer.
  //
  // Explicitly deferred: window.opener identity, JavaScript popup object
  // identity, OAuth child-window scripting and custom popup dimensions. Only
  // ordinary target=_blank / window.open navigation is routed to a tab.
  const std::string url = target_url.ToString();
  if (!url.empty()) {
    NSString *value = NSStringFromCefString(target_url);
    __weak BrowserBridge *bridge = bridge_;
    OnMainThread(^{
      [bridge browserDidRequestPopup:value];
    });
  }
  return true;  // Cancel the unmanaged popup.
}

bool CEFClientHandler::OnSetFocus(CefRefPtr<CefBrowser> browser,
                                   FocusSource source) {
  // Chromium asks for the keyboard here, for example when a browser starts
  // navigating - which happens asynchronously, long after the tab may have been
  // hidden again. The answer is decided by the runtime owner of this browser
  // (BrowserSession), which knows whether this surface is still the visible
  // selected one, so a background tab can never steal AppKit's first responder
  // by starting a load (Milestone 3 focus fix).
  //
  // Answered synchronously on the UI thread: CEF uses the return value to decide
  // whether to move focus, so there is nothing to hop to another thread here.
  __weak BrowserBridge *bridge = bridge_;
  const bool fromSystem = (source == FOCUS_SOURCE_SYSTEM);
  return ![bridge browserRequestsFocusFromSystem:fromSystem];
}

void CEFClientHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  browser_ = browser;
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidCreate];
  });
}

bool CEFClientHandler::DoClose(CefRefPtr<CefBrowser> browser) {
  NSLog(@"[browser] DoClose %d", browser->GetIdentifier());
  // The application owns the window that hosts the browser view, so handle the
  // close notification here instead of letting CEF send it to the window
  // (performClose: does nothing when the window is not key, which would leave
  // the browser alive indefinitely). Removing the Chromium view from the view
  // hierarchy completes the close and OnBeforeClose() follows.
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge completeClose];
  });
  return true;
}

void CEFClientHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  NSLog(@"[browser] OnBeforeClose %d", browser->GetIdentifier());
  browser_ = nullptr;
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidClose];
  });
}

void CEFClientHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                            bool isLoading,
                                            bool canGoBack,
                                            bool canGoForward) {
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidUpdateLoadingState:isLoading
                               canGoBack:canGoBack
                            canGoForward:canGoForward];
  });
}

void CEFClientHandler::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefFrame> frame,
                                 int httpStatusCode) {
  if (frame == nullptr || !frame->IsMain()) {
    return;
  }
  // GetURL() is read at completion time, after redirects have committed. Do
  // not log it: the complete URL may contain credentials or a token.
  NSString *url = NSStringFromCefString(frame->GetURL());
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidFinishMainFrameLoadWithURL:url];
  });
}

void CEFClientHandler::OnLoadError(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   ErrorCode errorCode,
                                   const CefString &errorText,
                                   const CefString &failedUrl) {
  if (frame == nullptr || !frame->IsMain()) {
    return;
  }
  // ERR_ABORTED is reported for ordinary navigation changes (for example when a
  // redirect replaces the pending navigation) and is not a failure the user
  // needs to see (ARCHITECTURE.md section 31).
  if (errorCode == ERR_ABORTED) {
    return;
  }
  NSString *text = NSStringFromCefString(errorText);
  NSString *url = NSStringFromCefString(failedUrl);
  const NSInteger code = static_cast<NSInteger>(errorCode);
  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidFailLoadWithError:text errorCode:code failedURL:url];
  });
}

bool CEFClientHandler::CanDownload(CefRefPtr<CefBrowser> browser,
                                   const CefString &url,
                                   const CefString &request_method) {
  // The application has no policy that blocks a browser download. Returning
  // this explicitly keeps the installed CEF download flow on the typed path
  // instead of relying on CefDownloadHandler's default implementation.
  return true;
}

bool CEFClientHandler::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString &suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  if (download_item == nullptr || callback == nullptr) {
    return false;
  }

  const NSInteger downloadIdentifier = static_cast<NSInteger>(download_item->GetId());
  NSString *sourceURL = NSStringFromCefString(download_item->GetURL());
  NSString *suggestedFileName = NSStringFromCefString(suggested_name);
  NSString *cefSuggestedFileName =
      NSStringFromCefString(download_item->GetSuggestedFileName());
  NSString *contentDisposition =
      NSStringFromCefString(download_item->GetContentDisposition());
  NSString *mimeType = NSStringFromCefString(download_item->GetMimeType());
  NSString *originalURL = NSStringFromCefString(download_item->GetOriginalUrl());
  __weak BrowserBridge *bridge = bridge_;
  CefRefPtr<CefBeforeDownloadCallback> callbackRef = callback;

  OnMainThread(^{
    NSString *destination = [bridge downloadDestinationPathForIdentifier:downloadIdentifier
                                                                 sourceURL:sourceURL
                                                           suggestedFileName:suggestedFileName
                                                        cefSuggestedFileName:cefSuggestedFileName
                                                         contentDisposition:contentDisposition
                                                                 mimeType:mimeType
                                                              originalURL:originalURL];
    std::string path = destination != nil ? std::string(destination.UTF8String) : std::string();
    callbackRef->Continue(path, /*show_dialog=*/false);
  });
  // We call Continue ourselves, synchronously or asynchronously on the main
  // actor. Returning true prevents CEF's Alloy default from cancelling it.
  return true;
}

void CEFClientHandler::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  if (download_item == nullptr) {
    return;
  }

  const NSInteger downloadIdentifier = static_cast<NSInteger>(download_item->GetId());
  NSString *sourceURL = NSStringFromCefString(download_item->GetURL());
  NSString *suggestedFileName = NSStringFromCefString(download_item->GetSuggestedFileName());
  NSString *cefSuggestedFileName = suggestedFileName;
  NSString *contentDisposition =
      NSStringFromCefString(download_item->GetContentDisposition());
  NSString *mimeType = NSStringFromCefString(download_item->GetMimeType());
  NSString *originalURL = NSStringFromCefString(download_item->GetOriginalUrl());
  NSString *destinationPath = NSStringFromCefString(download_item->GetFullPath());
  const long long receivedBytes = static_cast<long long>(download_item->GetReceivedBytes());
  const long long totalBytes = static_cast<long long>(download_item->GetTotalBytes());
  const BOOL hasTotalBytes = totalBytes > 0;
  const BOOL isInProgress = download_item->IsInProgress();
  const BOOL isComplete = download_item->IsComplete();
  const BOOL isCanceled = download_item->IsCanceled();
  const BOOL isInterrupted = download_item->IsInterrupted();

  if (callback != nullptr && isInProgress && !isCanceled && !isInterrupted) {
    active_downloads_[static_cast<uint32_t>(downloadIdentifier)] = callback;
  } else {
    active_downloads_.erase(static_cast<uint32_t>(downloadIdentifier));
  }

  __weak BrowserBridge *bridge = bridge_;
  OnMainThread(^{
    [bridge browserDidUpdateDownloadWithIdentifier:downloadIdentifier
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
  });
}
