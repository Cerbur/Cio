//
//  BrowserToolbarView.swift
//  NativeBrowser
//
//  Native compact navigation chrome: Back, Forward, Reload/Stop and the one
//  AppKit address field above the Chromium content.
//
//  The toolbar only ever reads BrowserSession.navigationState and calls the
//  session's navigation methods, so there is exactly one owner of navigation
//  state and one owner of the CEF browser.
//

import AppKit
import SwiftUI

struct BrowserToolbarView: View {
  @ObservedObject var session: BrowserSession
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    let state = session.navigationState

    HStack(spacing: 5) {
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

      Rectangle()
        .fill(Color.primary.opacity(0.12))
        .frame(width: 0.5, height: 18)
        .padding(.horizontal, 3)

      HStack(spacing: 7) {
        Image(systemName: "globe")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 16)

        AddressField(
          model: session.addressField,
          onChange: { session.addressField.userChangedText($0) },
          onSubmit: { session.submitAddressField() },
          onEscape: { session.cancelAddressEditing() },
          onFocusChange: { focused in
            interaction.isFocused = focused
            session.addressFieldFocusChanged(focused)
          }
        )
        .frame(minWidth: 240, maxWidth: .infinity, minHeight: 22, idealHeight: 24)
        .layoutPriority(1)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 2)
      .browserCompactGlass(cornerRadius: 15)
      .overlay {
        Capsule(style: .continuous)
          .strokeBorder(
            interaction.isFocused || session.addressField.isEditing
              ? Color.accentColor.opacity(0.45)
              : Color.primary.opacity(0.11),
            lineWidth: interaction.isFocused || session.addressField.isEditing ? 1 : 0.5
          )
      }

      if state.isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .scaleEffect(0.6)
          .frame(width: 14, height: 14)
          .help("Loading")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .frame(minHeight: 46)
    .browserToolbarMaterial()
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.09))
        .frame(height: 0.5)
        .allowsHitTesting(false)
    }
  }

  private func historyButton(
    systemImage: String,
    label: String,
    enabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    ToolbarIconButton(systemImage: systemImage, label: label, enabled: enabled, action: action)
  }

  /// A small semantic hover target. It changes only the button chrome; it never
  /// selects a tab or touches browser focus.
  private struct ToolbarIconButton: View {
    let systemImage: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @StateObject private var interaction = BrowserInteractionState()

    var body: some View {
      Button(action: action) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.42))
          .frame(width: 26, height: 26)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(
                interaction.isHovered && enabled
                  ? Color.primary.opacity(0.08) : Color.clear
              )
          )
          .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(!enabled)
      .onHover { interaction.isHovered = $0 }
      .help(label)
      .accessibilityLabel(label)
    }
  }

  private func reloadOrStopButton(isLoading: Bool) -> some View {
    ToolbarIconButton(
      systemImage: isLoading ? "xmark" : "arrow.clockwise",
      label: isLoading ? "Stop" : "Reload",
      enabled: true,
      action: session.reloadOrStop)
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
/// the object, so a mounted field can only ever react to its own session's ⌘L.
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

/*
 The remaining command behavior intentionally stays unchanged: the native
 AppKit field owns IME composition, Escape and Return, and the existing
 identity-scoped focus notifications keep ⌘L out of the Chromium surface.
*/
