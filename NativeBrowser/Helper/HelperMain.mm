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
#include "../Bridge/InspectorFrontend.h"

#include "include/cef_app.h"
#include "include/cef_frame.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

namespace {

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
      let nextCall = 0;
      let nextProtocolCall = -1;
      let frontendZoom = 1;
      const callbacks = new Map();
      const protocolCallbacks = new Map();
      const request = (method, params, callback) => {
        const id = ++nextCall;
        if (callback) callbacks.set(id, callback);
        nativeBrowserInspectorSend('host', JSON.stringify({id, method, params}));
      };
      globalThis.nativeBrowserInspectorReply = (id, value) => {
        const callback = callbacks.get(id);
        callbacks.delete(id);
        callback?.(value);
      };
      globalThis.nativeBrowserInspectorSetZoom = factor => {
        frontendZoom = factor;
        window.dispatchEvent(new Event('resize'));
      };
      // Source maps and other developer resources use the inspected page's
      // network context. Private CDP replies never enter the frontend's queue.
      const protocol = (method, params) => new Promise((resolve, reject) => {
        const id = nextProtocolCall--;
        protocolCallbacks.set(id, {resolve, reject});
        nativeBrowserInspectorSend('protocol', JSON.stringify({id, method, params}));
      });
      globalThis.nativeBrowserInspectorDispatch = message => {
        const data = JSON.parse(message);
        const callback = protocolCallbacks.get(data.id);
        if (callback) {
          protocolCallbacks.delete(data.id);
          data.error ? callback.reject(data.error) : callback.resolve(data.result);
        } else {
          globalThis.InspectorFrontendAPI?.dispatchMessage(message);
        }
      };
      const preferences = () => {
        const result = {};
        for (let i = 0; i < localStorage.length; ++i) {
          const key = localStorage.key(i);
          if (key.startsWith('cio.devtools.')) result[key.slice(13)] = localStorage.getItem(key);
        }
        result['currentDockState'] ||= JSON.stringify('bottom');
        result['current-dock-state'] ||= JSON.stringify('bottom');
        return result;
      };
      const overrides = {
        platform: () => 'mac', isHostedMode: () => false,
        sendMessageToBackend: message => nativeBrowserInspectorSend('protocol', message),
        closeWindow: () => nativeBrowserInspectorSend('close', ''),
        getHostConfig: callback => callback({}),
        getPreferences: callback => callback(preferences()),
        getPreference: (name, callback) => callback(preferences()[name] || ''),
        setPreference: (name, value) => localStorage.setItem('cio.devtools.' + name, value),
        removePreference: name => localStorage.removeItem('cio.devtools.' + name),
        clearPreferences: () => {
          for (const key of Object.keys(preferences())) localStorage.removeItem('cio.devtools.' + key);
        },
        getSyncInformation: callback => callback({isSyncActive:false, arePreferencesSynced:false}),
        loadCompleted: () => request('ready', []),
        bringToFront: () => request('front', []),
        inspectedURLChanged: () => {},
        setInspectedPageBounds: bounds => request('bounds', [bounds]),
        setIsDocked: (docked, callback) => {
          const side = docked ? (['bottom', 'left', 'right'].find(side => document.body.classList.contains(side)) || 'bottom') : 'undocked';
          request('dock', [side], callback);
        },
        copyText: text => request('copy', [text || '']),
        openInNewTab: url => request('open', [url]),
        openSearchResultsInNewTab: query => request('open', ['https://www.google.com/search?q=' + encodeURIComponent(query)]),
        save: (url, content, forceSaveAs, isBase64) => request('save', [url, content, forceSaveAs, isBase64]),
        append: (url, content) => request('append', [url, content]),
        zoomFactor: () => frontendZoom,
        zoomIn: () => request('zoom', [1]),
        zoomOut: () => request('zoom', [-1]),
        resetZoom: () => request('zoom', [0]),
        reattach: callback => callback?.(),
        // CEF supplies page/worker targets through CDP. It has no Chrome
        // profile workspace service; finish discovery instead of hanging boot.
        requestFileSystems: () => globalThis.InspectorFrontendAPI?.fileSystemsLoaded([]),
        loadNetworkResource: async (url, headers, streamId, callback) => {
          let stream;
          try {
            const {frameTree} = await protocol('Page.getFrameTree', {});
            const {resource} = await protocol('Network.loadNetworkResource', {
              frameId:frameTree.frame.id, url, options: {disableCache:false, includeCredentials:true},
            });
            stream = resource.stream;
            if (resource.success && stream) {
              const decoder = new TextDecoder();
              for (;;) {
                const part = await protocol('IO.read', {handle:stream});
                const text = part.base64Encoded
                  ? decoder.decode(Uint8Array.from(atob(part.data), c => c.charCodeAt(0)), {stream:!part.eof}) : part.data;
                globalThis.InspectorFrontendAPI.streamWrite(streamId, text);
                if (part.eof) break;
              }
            }
            callback({statusCode:resource.httpStatusCode || (resource.success ? 200 : 0),
              headers:resource.headers || {}, netError:resource.netError || 0,
              netErrorName:resource.netErrorName || '', urlValid:true});
          } catch (error) {
            callback({statusCode:0, netError:-2, netErrorName:error.message || 'Resource load failed', urlValid:true});
          } finally {
            if (stream) await protocol('IO.close', {handle:stream}).catch(() => {});
          }
        },
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
