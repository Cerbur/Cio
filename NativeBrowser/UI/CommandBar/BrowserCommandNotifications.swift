//
//  BrowserCommandNotifications.swift
//  NativeBrowser
//
//  The two notifications the browser command layer and the address field use to
//  coordinate focus (⌘L, Milestone 2 section 13).
//
//  AppKit menu key equivalents are dispatched by NSMenu before the first
//  responder sees the event, so ⌘L reaches the application even while the
//  Chromium view owns the keyboard. A command publishes the focus request and
//  the matching address field, which is the only object that can ask its window
//  for first responder status, reacts to it.
//

import Foundation

extension Notification.Name {
  /// Posted by a browser command (⌘L) to ask the address field to take focus.
  /// The notification's object is the BrowserSession whose field should focus.
  static let browserFocusAddressField = Notification.Name("NativeBrowser.focusAddressField")

  /// Posted by the toolbar once it has matched a focus request to its session.
  /// The notification's object is the BrowserSession; the address field of that
  /// session becomes first responder and selects all.
  static let browserAddressFieldShouldFocus = Notification.Name(
    "NativeBrowser.addressFieldShouldFocus")
}
