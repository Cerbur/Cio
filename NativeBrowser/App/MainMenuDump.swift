//
//  MainMenuDump.swift
//  NativeBrowser
//
//  Prints the application's main menu for the verification tooling
//  (--dump-main-menu).
//
//  Why: the scene installs AppKit's standard window Close item, which also uses
//  Command-W. Two items with the same key equivalent resolve by menu order,
//  which is not a contract worth depending on, so AppDelegate removes the window
//  item and Scripts/verify_milestone3.sh reads this dump to assert that exactly
//  one Command-W item exists and that it is the tab command (Milestone 3
//  section 21).
//
//  Tooling only: inert unless --dump-main-menu is passed.
//

import AppKit

@MainActor
enum MainMenuDump {
  /// Removes the scene's window Close item so Command-W belongs to the selected
  /// tab.
  ///
  /// Only the standard window-closing action is removed. The title-bar close
  /// button is unaffected: it calls -performClose: on the window directly and
  /// does not go through this menu item, so the red button still closes the
  /// window (and therefore, with
  /// applicationShouldTerminateAfterLastWindowClosed, the application).
  static func claimCloseTabShortcut() {
    guard let mainMenu = NSApp.mainMenu else { return }
    for topLevel in mainMenu.items {
      guard let submenu = topLevel.submenu else { continue }
      for item in submenu.items where isWindowCloseItem(item) {
        AppLog.app.info(
          "removed the window Close menu item so Command-W closes the selected tab")
        submenu.removeItem(item)
      }
    }
  }

  private static func isWindowCloseItem(_ item: NSMenuItem) -> Bool {
    guard !item.isSeparatorItem else { return false }
    guard item.keyEquivalent == "w" else { return false }
    guard item.keyEquivalentModifierMask == .command else { return false }
    let action = item.action.map(NSStringFromSelector) ?? ""
    return action == "performClose:" || action == "close"
  }

  /// Prints every menu item, one line each.
  static func printMainMenu(_ phase: String) {
    guard let mainMenu = NSApp.mainMenu else {
      print("main-menu(\(phase)): <none>")
      return
    }
    print("main-menu(\(phase)): begin")
    for topLevel in mainMenu.items {
      if let submenu = topLevel.submenu {
        for entry in submenu.items {
          print(line(menu: topLevel.title, item: entry))
        }
      } else {
        print(line(menu: topLevel.title, item: topLevel))
      }
    }
    print("main-menu(\(phase)): end")
  }

  private static func line(menu: String, item: NSMenuItem) -> String {
    let title = item.isSeparatorItem ? "<separator>" : item.title
    var modifiers: [String] = []
    let mask = item.keyEquivalentModifierMask
    if mask.contains(.control) { modifiers.append("ctrl") }
    if mask.contains(.option) { modifiers.append("opt") }
    if mask.contains(.shift) { modifiers.append("shift") }
    if mask.contains(.command) { modifiers.append("cmd") }
    let action = item.action.map(NSStringFromSelector) ?? "none"
    return
      "menu-item: \(menu)|\(title) key=\(item.keyEquivalent) mods=\(modifiers.joined(separator: "+")) action=\(action)"
  }
}
