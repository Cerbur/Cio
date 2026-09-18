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

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

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
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
