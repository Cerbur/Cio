//
//  NativeBrowserApp.swift
//  NativeBrowser
//
//  The SwiftUI application. Note the absence of @main: the process entry point
//  is BrowserMain so that the CEF sub-process hand-off can run before any UI
//  code (see ARCHITECTURE.md section 11).
//
//  A single `Window` scene, not a `WindowGroup`. The runtime owns exactly one
//  BrowserWorkspaceStore with one BrowserSessionManager, so a scene that could
//  create a second window would mount the same workspace and Chromium views in
//  two places. Per-window workspaces are a later milestone.
//
//  The browser commands (Command-L, Command-T, Command-W, Command-R, Command-[,
//  Command-]) are menu items so that AppKit dispatches them before the first
//  responder sees the key event, which is what makes them work while the
//  Chromium view owns the keyboard.
//

import SwiftUI

struct NativeBrowserApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var runtime = ApplicationRuntime.shared

  var body: some Scene {
    Window("NativeBrowser", id: "main") {
      MainWindowView()
        .environmentObject(runtime)
    }
    .defaultSize(width: 1280, height: 800)
    // Keep the system title bar and traffic lights. MainWindowView applies the
    // AppKit full-size-content configuration so the titlebar becomes part of
    // the continuous window chrome instead of reserving a second title row.
    .windowStyle(.titleBar)
    .commands {
      // The workspace store is a stable reference: command actions resolve the
      // selected tab when they run, so they always operate on the current
      // selection rather than on whatever was selected when the menu was built.
      BrowserCommands(workspace: runtime.workspaceStore)
    }
  }
}
