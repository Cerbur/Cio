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
//  Every command targets the *selected* session. The closures resolve
//  `manager.selectedSession` when they run instead of capturing a session, so a
//  menu item can never act on a tab that is no longer selected.
//

import SwiftUI

struct BrowserCommands: Commands {
  /// The runtime owner of the tabs. Stable for the application's lifetime.
  let manager: BrowserSessionManager

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("Back") { manager.selectedSession?.goBack() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!(manager.selectedSession?.canGoBack ?? false))

      Button("Forward") { manager.selectedSession?.goForward() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!(manager.selectedSession?.canGoForward ?? false))

      Button(selectedIsLoading ? "Stop" : "Reload") {
        manager.selectedSession?.reloadOrStop()
      }
      .keyboardShortcut("r", modifiers: .command)

      Divider()

      Button("Open Location…") { manager.selectedSession?.requestAddressFieldFocus() }
        .keyboardShortcut("l", modifiers: .command)
    }

    // Tabs. A dedicated menu keeps the tab lifecycle commands together and keeps
    // them away from AppKit's own File > Close item, which is removed in
    // AppDelegate so that Command-W cannot mean "close the window" while tabs
    // exist (section 21).
    CommandMenu("Tabs") {
      Button("New Tab") { manager.createTab(url: nil) }
        .keyboardShortcut("t", modifiers: .command)

      Button("Close Tab") { manager.closeSelectedTab() }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(manager.selectedTabID == nil)

      Button("Reopen Closed Tab") { manager.reopenLastClosedTab() }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!manager.canReopenClosedTab)

      Divider()

      // Optional positional shortcuts (section 23): Command-1…Command-8 select a
      // tab by position, Command-9 selects the last one.
      ForEach(1...9, id: \.self) { position in
        Button(position == 9 ? "Select Last Tab" : "Select Tab \(position)") {
          if position == 9 {
            manager.selectLastTab()
          } else {
            manager.selectTab(at: position - 1)
          }
        }
        .keyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: .command)
        .disabled(position == 9 ? manager.tabs.isEmpty : manager.tabs.count < position)
      }
    }
  }

  private var selectedIsLoading: Bool {
    manager.selectedSession?.isLoading ?? false
  }
}
