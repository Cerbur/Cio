//
//  HelperMain.mm
//  NativeBrowserHelper
//
//  Entry point for the Chromium helper processes (renderer, GPU, plugin,
//  alerts, utility). CEF launches these by re-executing the helper executable
//  inside "NativeBrowser Helper*.app" with a --type=<process> switch.
//
//  The helper deliberately contains no AppKit/SwiftUI code: it loads the CEF
//  framework from the browser process's app bundle and hands control to CEF.
//

#include <cstdio>
#include <set>

#include "include/cef_app.h"
#include "include/cef_frame.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

namespace {
constexpr char kInspectorURL[] = "devtools://devtools/bundled/devtools_app.html";
constexpr char kInspectorMessage[] = "NativeBrowser.Inspector";

class InspectorSendHandler final : public CefV8Handler {
 public:
  bool Execute(const CefString& name, CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments, CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    auto context = CefV8Context::GetCurrentContext();
    if (!context || !context->GetFrame()->IsMain() ||
        context->GetFrame()->GetURL().ToString() != kInspectorURL ||
        arguments.size() != 2 || !arguments[0]->IsString() || !arguments[1]->IsString()) return false;
    auto message = CefProcessMessage::Create(kInspectorMessage);
    message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    message->GetArgumentList()->SetString(1, arguments[1]->GetStringValue());
    context->GetFrame()->SendProcessMessage(PID_BROWSER, message);
    return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(InspectorSendHandler);
};

/// Only our explicitly marked inspector browser receives a native binding.
/// Navigating an ordinary tab to devtools:// never grants access to another tab.
class HelperApp final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (extra_info && extra_info->GetBool("nativeBrowserInspector"))
      inspectors_.insert(browser->GetIdentifier());
  }
  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    inspectors_.erase(browser->GetIdentifier());
  }
  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!inspectors_.contains(browser->GetIdentifier()) || !frame->IsMain() ||
        frame->GetURL().ToString() != kInspectorURL) return;
    context->GetGlobal()->SetValue("nativeBrowserInspectorSend",
        CefV8Value::CreateFunction("nativeBrowserInspectorSend", new InspectorSendHandler),
        static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTDELETE));
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> error;
    context->Eval(R"JS(
      const overrides = {
        platform: () => 'mac', isHostedMode: () => false,
        sendMessageToBackend: message => nativeBrowserInspectorSend('protocol', message),
        closeWindow: () => nativeBrowserInspectorSend('close', ''),
        getHostConfig: callback => callback({}),
        getPreferences: callback => callback(Object.assign({}, localStorage)),
        getPreference: (name, callback) => callback(localStorage.getItem(name) || ''),
        setPreference: (name, value) => localStorage.setItem(name, value),
        removePreference: name => localStorage.removeItem(name),
        clearPreferences: () => localStorage.clear(),
        getSyncInformation: callback => callback({isSyncActive:false, arePreferencesSynced:false}),
        loadCompleted: () => {}, bringToFront: () => {},
        inspectedURLChanged: () => {}, setInspectedPageBounds: () => {},
        setIsDocked: (_, callback) => callback && callback(),
        zoomFactor: () => 1,
      };
      // Blink installs devtools_compatibility.js after OnContextCreated. Keep
      // its complete Chromium host, replacing only our in-process transport
      // and the window operations owned by AppKit.
      let host = Object.assign(globalThis.InspectorFrontendHost || {}, overrides);
      Object.defineProperty(globalThis, 'InspectorFrontendHost', {
        configurable: true,
        get: () => host,
        set: value => { host = Object.assign(value, overrides); },
      });
    )JS", frame->GetURL(), 0, result, error);
  }
 private:
  std::set<int> inspectors_;
  IMPLEMENT_REFCOUNTING(HelperApp);
};
}  // namespace

int main(int argc, char *argv[]) {
#if defined(CEF_USE_SANDBOX)
  // Initialize the macOS sandbox for this helper process.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    fprintf(stderr, "[cef-helper] sandbox initialization failed\n");
    return 1;
  }
#endif

  // Load the CEF framework from the browser process's app bundle
  // ("../../.." relative to this executable).
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    fprintf(stderr, "[cef-helper] failed to load the CEF framework\n");
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, new HelperApp, nullptr);
}
