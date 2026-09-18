//
//  CEFClientHandler.mm
//  NativeBrowser
//

#import "CEFClientHandler.h"

#import "BrowserBridge.h"

#include <string>

#include "include/cef_browser.h"
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
  // Milestone 1 hosts exactly one browser, so allowing a popup would create a
  // window this application does not manage. Navigate the existing browser
  // instead; Milestone 3 (tabs) routes popups to a new tab instead
  // (ARCHITECTURE.md section 21).
  const std::string url = target_url.ToString();
  if (!url.empty()) {
    if (CefRefPtr<CefFrame> main_frame = browser->GetMainFrame()) {
      main_frame->LoadURL(url);
    }
  }
  return true;  // Cancel the popup.
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
