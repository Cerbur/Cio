//
//  AppCommands.swift
//  NativeBrowser
//
//  Browser menu commands and their key equivalents (Milestone 2 sections 13,
//  14 and 15).
//
//  These are AppKit menu items in the main menu, not SwiftUI keyboard
//  handlers: NSMenu matches a key equivalent before the event reaches the first
//  responder, so ⌘L, ⌘R, ⌘[ and ⌘] work while the Chromium view owns the
//  keyboard. There is no global key polling anywhere in the application.
//
//  The shell owns the shortcuts; Chromium's own menu-driven accelerators never
//  see them, which keeps browser-shell ownership of these keys explicit.
//

import SwiftUI

struct BrowserCommands: Commands {
  let session: BrowserSession

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("Back") { session.goBack() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!session.canGoBack)

      Button("Forward") { session.goForward() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!session.canGoForward)

      Button(session.isLoading ? "Stop" : "Reload") { session.reloadOrStop() }
        .keyboardShortcut("r", modifiers: .command)

      Divider()

      Button("Open Location…") { session.requestAddressFieldFocus() }
        .keyboardShortcut("l", modifiers: .command)
    }
  }
}
