//
//  CioApp.swift
//  Cio
//
//  The SwiftUI application. Note the absence of @main: the process entry point
//  is BrowserMain so that the Chromium sub-process hand-off can run before any UI
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

import CioChromium
import CioUI
import SwiftUI

struct CioApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var runtime = ApplicationRuntime.shared

  var body: some Scene {
    Window("Cio", id: "main") {
      MainWindowView()
        .environmentObject(runtime.uiContext)
    }
    .defaultSize(width: 1280, height: 800)
    // Hide SwiftUI's visual titlebar while keeping the titled NSWindow and its
    // native traffic lights, resizing, and full-screen behavior.
    .windowStyle(.hiddenTitleBar)
    .commands {
      // The workspace store is a stable reference: command actions resolve the
      // selected tab when they run, so they always operate on the current
      // selection rather than on whatever was selected when the menu was built.
      BrowserCommands(workspace: runtime.workspaceStore, runtime: runtime)
    }

    // SwiftUI installs the native Settings menu item and Command-comma, which
    // AppKit dispatches even while Chromium owns the browser's first responder.
    Settings {
      BrowserSettingsView { url in
        guard !runtime.workspaceStore.isTerminating else { return false }
        runtime.presentedInternalPanel = nil
        return runtime.workspaceStore.createTab(url: url, title: "设置") != nil
      }
    }
    .defaultSize(width: 760, height: 520)
  }
}
