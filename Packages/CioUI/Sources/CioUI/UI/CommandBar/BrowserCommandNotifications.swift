//
//  BrowserCommandNotifications.swift
//  Cio
//
//  Notifications coordinating browser menu commands with their UI owners,
//  including address focus (⌘L) and Space's sidebar/pin toggles (⌘S/⌘D).
//
//  AppKit menu key equivalents are dispatched by NSMenu before the first
//  responder sees the event, so ⌘L reaches the application even while the
//  Chromium view owns the keyboard. A command publishes the focus request and
//  the matching address field, which is the only object that can ask its window
//  for first responder status, reacts to it.
//

import Foundation

public extension Notification.Name {
  /// Space-only menu commands target the window/sidebar for this workspace.
  static let browserToggleSidebar = Notification.Name("Cio.toggleSidebar")
  static let browserToggleSpacePin = Notification.Name("Cio.toggleSpacePin")

  /// Posted by a browser command (⌘L) to ask the address field to take focus.
  /// The notification's object is the BrowserSession whose field should focus.
  static let browserFocusAddressField = Notification.Name("Cio.focusAddressField")

  /// Posted by the toolbar once it has matched a focus request to its session.
  ///
  /// The notification's object is that session's AddressFieldModel, not the
  /// session: the address field registers for its own model only, so with more
  /// than one field mounted a request can never focus the wrong one (Milestone 3
  /// section 15).
  static let browserAddressFieldShouldFocus = Notification.Name(
    "Cio.addressFieldShouldFocus")
}
