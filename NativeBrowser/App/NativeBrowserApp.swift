//
//  NativeBrowserApp.swift
//  NativeBrowser
//
//  The SwiftUI application. Note the absence of @main: the process entry point
//  is BrowserMain so that the CEF sub-process hand-off can run before any UI
//  code (see ARCHITECTURE.md section 11).
//

import SwiftUI

struct NativeBrowserApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var runtime = ApplicationRuntime.shared

  var body: some Scene {
    WindowGroup("NativeBrowser") {
      MainWindowView()
        .environmentObject(runtime)
    }
    .defaultSize(width: 1280, height: 800)
  }
}
