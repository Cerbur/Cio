//
//  BrowserSession+Commands.swift
//  NativeBrowser
//
//  Address-field behaviour: parsing what the user typed, submitting it, and
//  handing the keyboard back and forth between the native field and Chromium
//  (Milestone 2 sections 6, 7, 8, 13, 16 and 17).
//
//  Kept out of BrowserSession.swift so that file stays about browser state and
//  this one stays about user commands.
//

import AppKit
import Foundation

extension BrowserSession {
  // MARK: - Address field

  /// ⌘L: focus the address field with the committed URL and select all of it.
  func requestAddressFieldFocus() {
    AppLog.navigation.info("focus address field (command-L)")
    onLifecycleEvent?("navigation:focus-address-field")
    NotificationCenter.default.post(name: .browserFocusAddressField, object: self)
  }

  /// The field gained or lost keyboard focus.
  func addressFieldFocusChanged(_ focused: Bool) {
    setAddressFieldFocused(focused)
  }

  /// The user pressed Return in the address field (or in the middle of an IME
  /// composition that Return committed).
  func submitAddressField() {
    let text = addressField.editText
    // Editing ends before navigating: the Chromium URL callbacks that follow
    // must be allowed to update the field again (Milestone 2, section 6).
    addressField.endEditing()

    guard let input = parseNavigationInput(text) else {
      AppLog.navigation.debug("empty address input ignored")
      focusPage()
      return
    }

    switch input {
    case .url(let url):
      logAddressSubmission("URL", url.absoluteString)
      onLifecycleEvent?("navigation:parsed-as-url(\(url.absoluteString))")
      load(url)
    case .search(let query):
      let url = GoogleSearchEngine().searchURL(for: query)
      logAddressSubmission("search", url.absoluteString)
      onLifecycleEvent?("navigation:parsed-as-search(\(query))")
      load(url)
    }
    focusPage()
  }

  /// OSLog interpolates its argument, so the composed message is passed as one
  /// interpolated value rather than concatenated.
  private func logAddressSubmission(_ kind: String, _ url: String) {
    AppLog.navigation.info("address parsed as \(kind, privacy: .public): \(url, privacy: .public)")
  }

  /// Escape while editing: drop the unsubmitted edit, restore the committed URL
  /// and give the keyboard back to the page (Milestone 2, section 17).
  func cancelAddressEditing() {
    AppLog.navigation.info("address editing cancelled")
    onLifecycleEvent?("navigation:address-editing-cancelled")
    addressField.cancelEditing()
    setAddressFieldFocused(false)
    focusPage()
  }
}
