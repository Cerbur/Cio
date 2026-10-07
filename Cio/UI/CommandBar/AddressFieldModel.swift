//
//  AddressFieldModel.swift
//  Cio
//
//  Editing state for the native address field (Milestone 2, section 6).
//
//  There are two independent pieces of state here on purpose:
//
//    committedURL  the main-frame URL Chromium last reported
//    editText      what the user is typing right now
//
//  Chromium keeps updating committedURL while the user types, but it may only
//  overwrite editText when the user is not editing. That is what stops an
//  unrelated URL callback from wiping out a half-typed address. The rule is
//  expressed as a flag rather than a timer: there is no timing involved and no
//  window in which the edit buffer can be clobbered.
//

import CioEngine
import AppKit
import Foundation
import OSLog

@MainActor
final class AddressFieldModel: BrowserAddressEditing {
  /// Address bar text shown when Chromium has no page yet.
  static let placeholder = "Search or enter website name"

  /// The main-frame URL Chromium last reported.
  @Published private(set) var committedURL: URL?
  /// The full address (or the user's unsubmitted text) used while focused.
  @Published private(set) var editText = ""
  /// True between the first keystroke and submit/cancel.
  @Published private(set) var isEditing = false

  private let log = AppLog.navigation

  // MARK: - Editing

  /// Records a keystroke without treating it as navigation.
  ///
  /// Returns `true` when the value actually changed and the field needs to be
  /// written back.
  @discardableResult
  func userChangedText(_ text: String) -> Bool {
    guard text != editText else { return false }
    editText = text
    isEditing = true
    return true
  }

  /// Ends editing: the next Chromium URL update is mirrored again.
  func endEditing() {
    if isEditing {
      editText = displayText(for: committedURL)
    }
    isEditing = false
  }

  /// Abandons the unsubmitted edit and restores the committed URL.
  func cancelEditing() {
    isEditing = false
    editText = displayText(for: committedURL)
  }

  // MARK: - Browser state

  /// Applies the main-frame URL Chromium reported.
  ///
  /// While the user is editing this only updates the committed value; the edit
  /// buffer is left alone so an unrelated callback cannot move the text under
  /// the cursor (Milestone 2, section 6).
  func applyBrowserURL(_ url: URL?) {
    committedURL = url
    guard !isEditing else {
      log.debug("main-frame URL changed while editing; edit buffer preserved")
      return
    }
    editText = displayText(for: url)
  }

  /// Text presented for a committed URL. `nil` (no page yet) shows an empty
  /// field rather than the placeholder, so the placeholder is visible.
  func displayText(for url: URL?) -> String {
    url?.absoluteString ?? ""
  }

  /// The address shown without focus. For URLs with a host, show only that
  /// host and drop a leading www. URLs without a host keep their full form.
  func compactDisplayText(for url: URL?) -> String {
    guard let url else { return "" }
    guard let host = url.host, !host.isEmpty else { return url.absoluteString }
    let visibleHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return visibleHost.contains(":") ? "[\(visibleHost)]" : visibleHost
  }

  /// Retained for a future mode that includes the full path in the unfocused
  /// address. The current presentation uses only `compactDisplayText(for:)`.
  func compactDisplayTextIncludingPath(for url: URL?) -> String {
    guard let url else { return "" }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          let host = components.host else {
      return url.absoluteString
    }

    let visibleHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let formattedHost = visibleHost.contains(":") ? "[\(visibleHost)]" : visibleHost
    let port = components.port.map { ":\($0)" } ?? ""
    var path = components.percentEncodedPath
    if path.hasSuffix("/") {
      path.removeLast()
    }
    return formattedHost + port + path
  }
}
