//
//  CEFClientHandler.h
//  NativeBrowser
//
//  CefClient implementation for a single Chromium browser instance.
//
//  Chromium callbacks are translated into BrowserBridge delegate events here;
//  no CEF type crosses the bridge boundary (ARCHITECTURE.md section 8).
//
//  This header intentionally exposes C++ types and is therefore never included
//  from Swift or from the bridging header.
//

#import <Foundation/Foundation.h>

#include <map>

#include "include/cef_client.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_request_handler.h"

@class BrowserBridge;

class CEFClientHandler final : public CefClient,
                               public CefDisplayHandler,
                               public CefFocusHandler,
                               public CefLifeSpanHandler,
                               public CefLoadHandler,
                               public CefDownloadHandler,
                               public CefJSDialogHandler,
                               public CefRequestHandler {
 public:
  explicit CEFClientHandler(BrowserBridge *bridge);

  /// The browser owned by this client, once CefLifeSpanHandler::OnAfterCreated
  /// has run. Cleared again by OnBeforeClose.
  CefRefPtr<CefBrowser> browser() const { return browser_; }

  /// Cancels any download that is still active when the owning browser is
  /// being torn down. The callbacks stay entirely inside the CEF boundary;
  /// Swift receives the resulting cancelled update as a value event.
  void CancelActiveDownloads();

  /// Resolves the one pending beforeunload callback. The CEF callback remains
  /// inside this class so no CEF type crosses the Objective-C/Swift bridge.
  void ContinueBeforeUnload(bool accept);

  // CefClient
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefFocusHandler
  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override;

  // CefDisplayHandler
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString &title) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString> &icon_urls) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                               double progress) override;

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
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
                     bool *no_javascript_access) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefJSDialogHandler
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString &message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override;
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;

  // CefRequestHandler
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString &error_string) override;

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString &errorText,
                   const CefString &failedUrl) override;

  // CefDownloadHandler
  bool CanDownload(CefRefPtr<CefBrowser> browser,
                   const CefString &url,
                   const CefString &request_method) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString &suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

 private:
  /// Bridge that receives the translated callbacks. Weak: the browser never
  /// outlives the bridge that owns it.
  __weak BrowserBridge *bridge_;

  CefRefPtr<CefBrowser> browser_;
  std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> active_downloads_;
  CefRefPtr<CefJSDialogCallback> before_unload_callback_;

  IMPLEMENT_REFCOUNTING(CEFClientHandler);
  DISALLOW_COPY_AND_ASSIGN(CEFClientHandler);
};
