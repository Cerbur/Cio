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
  var showsSidebarToggle = false
  var titlebarContentInset: CGFloat = 0
  var onShowSidebar: () -> Void = {}
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    let state = session.navigationState
    let addressFieldIsFocused = interaction.isFocused || session.addressField.isEditing

    VStack(spacing: 0) {
      if showsSidebarToggle {
        // The full-size content view reaches into the titlebar. Keep the
        // collapsed toolbar's controls below the measured native titlebar
        // geometry so they never compete with the traffic lights.
        Color.clear
          .frame(height: max(titlebarContentInset, 8))
      }

      HStack(spacing: 0) {
        if showsSidebarToggle {
          BrowserGlassIconButton(
            systemImage: "sidebar.left",
            label: "Show Sidebar",
            action: onShowSidebar)
            .padding(.trailing, 6)
        }

        BrowserGlassControlGroup {
          BrowserGlassIconButton(
            systemImage: "chevron.backward",
            label: "Back",
            isEnabled: state.canGoBack,
            action: session.goBack)
          BrowserGlassIconButton(
            systemImage: "chevron.forward",
            label: "Forward",
            isEnabled: state.canGoForward,
            action: session.goForward)
          reloadOrStopButton(isLoading: state.isLoading)
        }

        Rectangle()
          .fill(Color.primary.opacity(0.12))
          .frame(width: 0.5, height: 18)
          .padding(.horizontal, 8)
          .allowsHitTesting(false)

        addressFieldSurface(isFocused: addressFieldIsFocused)
          .layoutPriority(1)

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
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(minHeight: 44)
    }
    .browserToolbarMaterial()
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.09))
        .frame(height: 0.5)
        .allowsHitTesting(false)
    }
  }

  private func addressFieldSurface(isFocused: Bool) -> some View {
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
    .browserAddressFieldSurface(
      isFocused: isFocused,
      cornerRadius: 10)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isFocused
            ? Color.accentColor.opacity(0.38)
            : Color.primary.opacity(0.13),
          lineWidth: isFocused ? 1 : 0.5
        )
        // The surface is decorative. If it participates in hit testing it
        // sits above the embedded NSTextField and can consume a normal mouse
        // click before AppKit's field editor gets a chance to become first
        // responder.
        .allowsHitTesting(false)
    }
    .allowsHitTesting(true)
  }

  private func reloadOrStopButton(isLoading: Bool) -> some View {
    BrowserGlassIconButton(
      systemImage: isLoading ? "xmark" : "arrow.clockwise",
      label: isLoading ? "Stop" : "Reload",
      isEnabled: true,
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
