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

#include "include/cef_client.h"

@class BrowserBridge;

class CEFClientHandler final : public CefClient,
                               public CefDisplayHandler,
                               public CefLifeSpanHandler,
                               public CefLoadHandler {
 public:
  explicit CEFClientHandler(BrowserBridge *bridge);

  /// The browser owned by this client, once CefLifeSpanHandler::OnAfterCreated
  /// has run. Cleared again by OnBeforeClose.
  CefRefPtr<CefBrowser> browser() const { return browser_; }

  // CefClient
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  // CefDisplayHandler
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString &title) override;
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

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString &errorText,
                   const CefString &failedUrl) override;

 private:
  /// Bridge that receives the translated callbacks. Weak: the browser never
  /// outlives the bridge that owns it.
  __weak BrowserBridge *bridge_;

  CefRefPtr<CefBrowser> browser_;

  IMPLEMENT_REFCOUNTING(CEFClientHandler);
  DISALLOW_COPY_AND_ASSIGN(CEFClientHandler);
};
