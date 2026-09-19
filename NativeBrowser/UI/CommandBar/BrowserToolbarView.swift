//
//  BrowserToolbarView.swift
//  NativeBrowser
//
//  Milestone 2 navigation UI: Back, Forward, Reload/Stop and the address field,
//  above the Chromium content. Deliberately visually plain - the Liquid Glass
//  treatment is Milestone 5 (ARCHITECTURE.md section 38).
//
//  The toolbar only ever reads BrowserSession.navigationState and calls the
//  session's navigation methods, so there is exactly one owner of navigation
//  state and one owner of the CEF browser.
//

import AppKit
import SwiftUI

struct BrowserToolbarView: View {
  @ObservedObject var session: BrowserSession

  var body: some View {
    let state = session.navigationState

    HStack(spacing: 6) {
      historyButton(
        systemImage: "chevron.backward",
        label: "Back",
        enabled: state.canGoBack,
        action: session.goBack)
      historyButton(
        systemImage: "chevron.forward",
        label: "Forward",
        enabled: state.canGoForward,
        action: session.goForward)
      reloadOrStopButton(isLoading: state.isLoading)

      AddressField(
        model: session.addressField,
        onChange: { session.addressField.userChangedText($0) },
        onSubmit: { session.submitAddressField() },
        onEscape: { session.cancelAddressEditing() },
        onFocusChange: { session.addressFieldFocusChanged($0) }
      )
      .frame(minWidth: 240, maxWidth: .infinity, minHeight: 21, idealHeight: 24)
      .layoutPriority(1)

      if state.isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .scaleEffect(0.6)
          .frame(width: 14, height: 14)
          .help("Loading")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(height: 44)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func historyButton(
    systemImage: String,
    label: String,
    enabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help(label)
    .accessibilityLabel(label)
  }

  /// One control, two behaviours: Reload while idle, Stop while loading
  /// (Milestone 2, section 11). The loading state comes from CEF.
  private func reloadOrStopButton(isLoading: Bool) -> some View {
    Button(action: session.reloadOrStop) {
      Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .help(isLoading ? "Stop" : "Reload")
    .accessibilityLabel(isLoading ? "Stop" : "Reload")
  }
}

/// Applies a ⌘L focus request to the AppKit address field.
///
/// This is a modifier on the toolbar rather than logic inside AddressField so
/// that the field itself stays a plain text field and the request is observed
/// once per command.
///
/// Milestone 3 mounts exactly one toolbar, but the two identity checks here are
/// what keep that from being load-bearing: the request is only accepted for
/// *this* session, and it is forwarded with the session's AddressFieldModel as
/// the object, so a mounted field can only ever react to its own session's ⌘L
/// (section 15).
private struct AddressFieldFocusListener: ViewModifier {
  let session: BrowserSession

  func body(content: Content) -> some View {
    content.onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressField)) {
      notification in
      guard notification.object as AnyObject? === session else { return }
      NotificationCenter.default.post(
        name: .browserAddressFieldShouldFocus, object: session.addressField)
    }
  }
}

extension View {
  /// Makes the address field of the session take focus when ⌘L is pressed.
  func addressFieldFocusListener(session: BrowserSession) -> some View {
    modifier(AddressFieldFocusListener(session: session))
  }
}
