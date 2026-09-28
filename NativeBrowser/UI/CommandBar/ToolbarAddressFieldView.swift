//
//  ToolbarAddressFieldView.swift
//  NativeBrowser
//
//  The toolbar's address capsule: the tab favicon, the native address field
//  and the capsule glass that carries the focus ring.
//
//  BrowserToolbarController owns the NSToolbarItem and the navigation
//  buttons; everything inside the address item lives here, so the capsule's
//  geometry has exactly one definition.
//

import AppKit
import SwiftUI

/// Geometry of the address capsule, shared by the SwiftUI contents and the
/// NSToolbarItem that hosts them.
///
/// The corner radius is half the height, which makes each end of the pill a
/// full circle of radius `height / 2`. The favicon is inset by that radius
/// minus half its own width, so its centre lands on the centre of the left
/// cap: the icon then keeps the same distance to the curved edge above,
/// below and beside it, instead of hugging the flat part of the pill.
enum AddressCapsuleLayout {
  static let height: CGFloat = 36
  static let cornerRadius = height / 2
  static let minimumWidth: CGFloat = 240
  /// Width the hosting view starts at before the toolbar stretches it.
  static let preferredWidth: CGFloat = 320
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
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    Group {
      if let session = workspace.selectedSession {
        addressField(for: session)
      } else {
        Color.clear
          .accessibilityHidden(true)
      }
    }
    .frame(minWidth: AddressCapsuleLayout.minimumWidth, maxWidth: .infinity)
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
        }
      )
      .frame(minWidth: AddressCapsuleLayout.minimumWidth, maxWidth: .infinity,
             minHeight: AddressCapsuleLayout.textMinimumHeight,
             idealHeight: AddressCapsuleLayout.textIdealHeight)
      .layoutPriority(1)
      .contentShape(Rectangle())
      .allowsHitTesting(true)
    }
    .padding(.leading, AddressCapsuleLayout.leadingInset)
    .padding(.trailing, AddressCapsuleLayout.trailingInset)
    .frame(minWidth: AddressCapsuleLayout.minimumWidth, maxWidth: .infinity)
    .frame(height: AddressCapsuleLayout.height)
    .browserAddressFieldSurface(cornerRadius: AddressCapsuleLayout.cornerRadius)
    .overlay {
      if interaction.isFocused || session.addressField.isEditing {
        RoundedRectangle(cornerRadius: AddressCapsuleLayout.cornerRadius,
                         style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressField)) {
      notification in
      guard (notification.object as? BrowserSession) === session else { return }
      NotificationCenter.default.post(
        name: .browserAddressFieldShouldFocus,
        object: session.addressField)
    }
  }
}
