//
//  AppCommands.swift
//  Cio
//
//  Browser menu commands and their key equivalents (Milestone 2 sections 13, 14
//  and 15; Milestone 3 sections 21, 22 and 23).
//
//  These are AppKit menu items in the main menu, not SwiftUI keyboard
//  handlers: NSMenu matches a key equivalent before the event reaches the first
//  responder, so they work while the Chromium view owns the keyboard. There is
//  no global key polling. Chromium's native pre-handler routes page-owned
//  shortcuts through this same menu, canonicalizing input-source '+' variants.
//
//  Every command targets the workspace's effective selected session. The
//  closures resolve `workspace.selectedSession` when they run instead of capturing a session, so a
//  menu item can never act on a tab that is no longer selected.
//

import CioUI
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

      Button("Reload Without Cache") {
        workspace.selectedSession?.reloadIgnoringCache()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(!(workspace.selectedSession?.hasBrowser ?? false)
                || (workspace.selectedSession?.isClosed ?? true))

      Divider()

      Button("Open Location…") {
        workspace.dismissSpotlight(focusPage: false)
        workspace.selectedSession?.requestAddressFieldFocus()
      }
        .keyboardShortcut("l", modifiers: .command)
    }

    CommandMenu("Extensions") {
      Button("Manage Extensions…") { runtime.openExtensionsPage() }
      Button("Chrome Web Store…") { runtime.openExtensionsPage(store: true) }
    }

    CommandMenu("Passwords") {
      Button("Manage Passwords…") { runtime.openPasswordsPage() }
        .disabled(!runtime.engineStatus.isReady || workspace.isTerminating)
      Button("Save or Update Password…") {
        workspace.dismissSpotlight(focusPage: false)
        if workspace.selectedSession?.showPendingPasswordPrompt() != true {
          runtime.openPasswordsPage()
        }
      }
      .disabled(runtime.presentedInternalPanel != nil || workspace.selectedSession?.hasBrowser != true)
    }

    CommandGroup(after: .textEditing) {
      Divider()
      Button("Copy Current Link") { workspace.focusedPageSession?.copyCurrentLink() }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(runtime.presentedInternalPanel != nil || workspace.isSpotlightPresented
                  || workspace.focusedPageSession?.hasBrowser != true
                  || workspace.focusedPageSession?.isClosed != false
                  || workspace.focusedPageSession?.url == nil)

      Button("Find in Page…") {
        workspace.dismissSpotlight(focusPage: false)
        workspace.selectedSession?.showFindBar()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(!canFindInPage)

      Button("Find Next") { workspace.selectedSession?.findNext() }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(!canFindInPage)
      Button("Find Previous") { workspace.selectedSession?.findPrevious() }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(!canFindInPage)
    }

    CommandMenu("Develop") {
      Button("View Page Source") { workspace.selectedSession?.viewPageSource() }
        .keyboardShortcut("u", modifiers: [.command, .option])
        .disabled(!(workspace.selectedSession?.hasBrowser ?? false)
                  || (workspace.selectedSession?.isClosed ?? true))
      Divider()
      if let session = workspace.selectedSession {
        WebInspectorMenuItem(session: session)
      } else {
        Button("Show Web Inspector") {}
          .keyboardShortcut("i", modifiers: [.command, .option])
          .disabled(true)
        Button("Toggle Web Inspector") {}
          .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [])
          .disabled(true)
      }
    }

    CommandGroup(after: .toolbar) {
      Button("Zoom In") { workspace.focusedPageSession?.zoomIn() }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(!canZoomPage)

      Button("Zoom Out") { workspace.focusedPageSession?.zoomOut() }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(!canZoomPage)

      Button("Actual Size") { workspace.focusedPageSession?.resetZoom() }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(!canZoomPage)

      Divider()

      Button("Toggle Sidebar") {
        guard runtime.presentedInternalPanel == nil else { return }
        NotificationCenter.default.post(name: .browserToggleSidebar, object: workspace)
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(runtime.presentedInternalPanel != nil)

      Button("Manage Spaces") {
        guard runtime.presentedInternalPanel == nil else { return }
        NotificationCenter.default.post(name: .browserToggleSpaceOverview, object: workspace)
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
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

      Divider()

      Button("Next Tab") { runtime.recentTabSwitcher.advance(forward: true) }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled(!canCycleTabs)

      Button("Previous Tab") { runtime.recentTabSwitcher.advance(forward: false) }
        // AppKit represents Shift-Tab as NSBackTabCharacter, not a tab with
        // only an extra modifier. This also works in native field editors.
        .keyboardShortcut(KeyEquivalent(Character("\u{19}")), modifiers: [.control, .shift])
        .disabled(!canCycleTabs)

      Divider()

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

  private var canFindInPage: Bool {
    runtime.presentedInternalPanel == nil && workspace.selectedSession?.isClosed == false
      && workspace.selectedSession?.rendererCrashed == false
      && workspace.selectedSession?.hasBrowser == true
  }

  private var canCycleTabs: Bool {
    runtime.presentedInternalPanel == nil && workspace.canCycleTabs
  }

  private var canZoomPage: Bool {
    runtime.presentedInternalPanel == nil && !workspace.isSpotlightPresented
      && workspace.focusedPageSession?.isClosed == false
      && workspace.focusedPageSession?.rendererCrashed == false
      && workspace.focusedPageSession?.hasBrowser == true
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

    Button("Toggle Web Inspector") { session.toggleDevTools() }
      .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [])
      .disabled(!session.hasBrowser || session.isClosed)
  }
}
