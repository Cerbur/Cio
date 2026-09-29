//
//  ToolbarAddressFieldView.swift
//  NativeBrowser
//
//  The toolbar's address capsule: the tab favicon, the native address field
//  and the capsule glass that carries the focus ring.
//
//  BrowserToolbarController positions this view above the Chromium view;
//  the capsule's appearance and editing behavior live here.
//

import AppKit
import SwiftUI

/// Geometry of the address capsule.
///
/// The corner radius is half the height, which makes each end of the pill a
/// full circle of radius `height / 2`. The favicon is inset by that radius
/// minus half its own width, so its centre lands on the centre of the left
/// cap: the icon then keeps the same distance to the curved edge above,
/// below and beside it, instead of hugging the flat part of the pill.
enum AddressCapsuleLayout {
  static let height: CGFloat = 36
  static let cornerRadius = height / 2
  static let unfocusedWidthRatio: CGFloat = 0.38
  static let focusedWidthRatio: CGFloat = 0.45
  static let faviconSize: CGFloat = 16
  static let faviconToTextSpacing: CGFloat = 7
  static let textMinimumHeight: CGFloat = 20
  static let textIdealHeight: CGFloat = 22
  /// Leading inset that centres the favicon on the left cap.
  static let leadingInset = cornerRadius - faviconSize / 2
  static let trailingInset: CGFloat = 8
}

struct ToolbarAddressFieldView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  var onFocusChange: () -> Void
  @StateObject private var interaction = BrowserInteractionState()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let session = workspace.selectedSession {
        addressField(for: session)
      } else {
        Color.clear
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: AddressCapsuleLayout.height)
  }

  private func addressField(for session: BrowserSession) -> some View {
    HStack(spacing: AddressCapsuleLayout.faviconToTextSpacing) {
      TabFaviconView(pageURL: session.url ?? workspace.selectedTab?.url,
                     session: session, size: AddressCapsuleLayout.faviconSize)
        .frame(width: AddressCapsuleLayout.faviconSize,
               height: AddressCapsuleLayout.faviconSize)
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      AddressField(
        model: session.addressField,
        onChange: { session.addressField.userChangedText($0) },
        onSubmit: { session.submitAddressField() },
        onEscape: { session.cancelAddressEditing() },
        onFocusChange: { focused in
          interaction.isFocused = focused
          session.addressFieldFocusChanged(focused)
          onFocusChange()
        }
      )
      .frame(maxWidth: .infinity,
             minHeight: AddressCapsuleLayout.textMinimumHeight,
             idealHeight: AddressCapsuleLayout.textIdealHeight)
      .layoutPriority(1)
      .contentShape(Rectangle())
      .allowsHitTesting(true)
    }
    .padding(.leading, AddressCapsuleLayout.leadingInset)
    .padding(.trailing, AddressCapsuleLayout.trailingInset)
    .frame(maxWidth: .infinity)
    .frame(height: AddressCapsuleLayout.height)
    .browserAddressFieldSurface(cornerRadius: AddressCapsuleLayout.cornerRadius)
    .contentShape(Capsule())
    .simultaneousGesture(TapGesture().onEnded {
      if !interaction.isFocused {
        session.requestAddressFieldFocus()
      }
    })
    .overlay {
      if interaction.isFocused || session.addressField.isEditing {
        RoundedRectangle(cornerRadius: AddressCapsuleLayout.cornerRadius,
                         style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16),
               value: interaction.isFocused)
    .onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressField)) {
      notification in
      guard (notification.object as? BrowserSession) === session else { return }
      NotificationCenter.default.post(
        name: .browserAddressFieldShouldFocus,
        object: session.addressField)
    }
  }
}
