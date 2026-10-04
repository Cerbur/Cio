//
//  AppCommands.swift
//  NativeBrowser
//
//  Browser menu commands and their key equivalents (Milestone 2 sections 13, 14
//  and 15; Milestone 3 sections 21, 22 and 23).
//
//  These are AppKit menu items in the main menu, not SwiftUI keyboard
//  handlers: NSMenu matches a key equivalent before the event reaches the first
//  responder, so they work while the Chromium view owns the keyboard. There is
//  no global key polling and no Chromium key interception anywhere in the
//  application.
//
//  Every command targets the workspace's effective selected session. The
//  closures resolve `workspace.selectedSession` when they run instead of capturing a session, so a
//  menu item can never act on a tab that is no longer selected.
//

import SwiftUI

struct BrowserCommands: Commands {
  /// The workspace/domain owner. Stable for the application's lifetime.
  @ObservedObject var workspace: BrowserWorkspaceStore
  @ObservedObject var runtime: ApplicationRuntime

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("Back") { workspace.selectedSession?.goBack() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!(workspace.selectedSession?.canGoBack ?? false))

      Button("Forward") { workspace.selectedSession?.goForward() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!(workspace.selectedSession?.canGoForward ?? false))

      Button(selectedIsLoading ? "Stop" : "Reload") {
        workspace.selectedSession?.reloadOrStop()
      }
      .keyboardShortcut("r", modifiers: .command)

      Divider()

      Button("Open Location…") {
        workspace.dismissSpotlight(focusPage: false)
        workspace.selectedSession?.requestAddressFieldFocus()
      }
        .keyboardShortcut("l", modifiers: .command)
    }

    CommandMenu("Develop") {
      if let session = workspace.selectedSession {
        WebInspectorMenuItem(session: session)
      } else {
        Button("Show Web Inspector") {}
          .keyboardShortcut("i", modifiers: [.command, .option])
          .disabled(true)
      }
    }

    CommandGroup(after: .toolbar) {
      Button("Toggle Sidebar") {
        guard runtime.presentedInternalPanel == nil else { return }
        NotificationCenter.default.post(name: .browserToggleSidebar, object: workspace)
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(runtime.presentedInternalPanel != nil)
    }

    // Tabs. A dedicated menu keeps the tab lifecycle commands together and keeps
    // them away from AppKit's own File > Close item, which is removed in
    // AppDelegate so that Command-W cannot mean "close the window" while tabs
    // exist (section 21).
    CommandMenu("Tabs") {
      Button("New Tab") { runtime.toggleSpotlight() }
        .keyboardShortcut("t", modifiers: .command)

      Button("Close Tab") { workspace.closeSelectedTab() }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(workspace.selectedTabID == nil)

      Button("Reopen Closed Tab") { workspace.reopenLastClosedTab() }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!workspace.canReopenClosedTab)

      Button(selectedIsSpacePin ? "Make Temporary" : "Pin in This Space") {
        guard runtime.presentedInternalPanel == nil, let id = workspace.selectedTabID,
              workspace.spacePinToggleTarget(for: id) != nil else { return }
        NotificationCenter.default.post(name: .browserToggleSpacePin, object: workspace,
                                        userInfo: ["tabID": id])
      }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(runtime.presentedInternalPanel != nil || !canToggleSelectedSpacePin)

      Divider()

      // Optional positional shortcuts (section 23): Command-1…Command-8 select a
      // tab by position, Command-9 selects the last one.
      ForEach(1...9, id: \.self) { position in
        Button(position == 9 ? "Select Last Tab" : "Select Tab \(position)") {
          if position == 9 {
            workspace.selectLastTab()
          } else {
            workspace.selectTab(at: position - 1)
          }
        }
        .keyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: .command)
        .disabled(position == 9 ? workspace.tabs.isEmpty : workspace.tabs.count < position)
      }
    }
  }

  private var selectedIsLoading: Bool {
    workspace.selectedSession?.isLoading ?? false
  }

  private var selectedIsSpacePin: Bool {
    workspace.selectedTabID.map { workspace.selectedSpace?.pinnedTabIDs.contains($0) == true } ?? false
  }

  private var canToggleSelectedSpacePin: Bool {
    workspace.selectedTabID.flatMap { workspace.spacePinToggleTarget(for: $0) } != nil
  }
}

/// Inspector state belongs to the runtime, so observe it directly rather than
/// waiting for unrelated URL/title metadata to make the workspace redraw.
private struct WebInspectorMenuItem: View {
  @ObservedObject var session: BrowserSession

  var body: some View {
    Button(session.isDevToolsOpen ? "Hide Web Inspector" : "Show Web Inspector") {
      session.toggleDevTools()
    }
    .keyboardShortcut("i", modifiers: [.command, .option])
    .disabled(!session.hasBrowser || session.isClosed)
  }
}
