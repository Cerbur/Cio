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
    let addressFieldIsFocused = interaction.isFocused || session.addressField.isEditing

    HStack(spacing: 0) {
      HStack(spacing: 2) {
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
      }

      Rectangle()
        .fill(Color.primary.opacity(0.12))
        .frame(width: 0.5, height: 18)
        .padding(.horizontal, 8)
        .allowsHitTesting(false)

      HStack(spacing: 7) {
        Image(systemName: "globe")
          .font(.system(size: 11, weight: .regular))
          .foregroundStyle(Color.secondary.opacity(0.88))
          .frame(width: 14)
          .allowsHitTesting(false)

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
        .frame(minWidth: 240, maxWidth: .infinity, minHeight: 20, idealHeight: 22)
        .layoutPriority(1)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
      .browserAddressFieldSurface(isFocused: addressFieldIsFocused, cornerRadius: 10)
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(
            addressFieldIsFocused
              ? Color.accentColor.opacity(0.38)
              : Color.primary.opacity(0.13),
            lineWidth: addressFieldIsFocused ? 1 : 0.5
          )
          // The surface is decorative. If it participates in hit testing it
          // sits above the embedded NSTextField and can consume a normal mouse
          // click before AppKit's field editor gets a chance to become first
          // responder.
          .allowsHitTesting(false)
      }
      .allowsHitTesting(true)

      ZStack {
        if state.isLoading {
          ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .scaleEffect(0.6)
            .help("Loading")
        }
      }
      .frame(width: 16, height: 14)
      .accessibilityHidden(!state.isLoading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(minHeight: 44)
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
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(
        ToolbarIconButtonStyle(enabled: enabled, isHovered: interaction.isHovered)
      )
      .disabled(!enabled)
      .onHover { interaction.isHovered = $0 }
      .help(label)
      .accessibilityLabel(label)
    }
  }

  private struct ToolbarIconButtonStyle: ButtonStyle {
    let enabled: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .foregroundStyle(
          enabled ? Color.primary.opacity(0.88) : Color.primary.opacity(0.38)
        )
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
              configuration.isPressed
                ? Color.primary.opacity(0.14)
                : (isHovered && enabled ? Color.primary.opacity(0.08) : Color.clear)
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
