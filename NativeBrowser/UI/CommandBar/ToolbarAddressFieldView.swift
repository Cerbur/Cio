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
  @StateObject private var interaction = BrowserInteractionState()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let isFocused = interaction.isFocused
        && workspace.selectedSession?.isEditingAddressField == true
      let widthRatio = isFocused
        ? 1 : AddressCapsuleLayout.unfocusedWidthRatio / AddressCapsuleLayout.focusedWidthRatio
      Group {
        if let session = workspace.selectedSession {
          addressField(for: session)
        } else {
          Color.clear
            .accessibilityHidden(true)
        }
      }
      .frame(width: geometry.size.width * widthRatio,
             height: AddressCapsuleLayout.height)
      .frame(width: geometry.size.width, height: AddressCapsuleLayout.height)
    }
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
          if reduceMotion {
            interaction.isFocused = focused
          } else {
            withAnimation(.spring(response: 0.31, dampingFraction: 0.68)) {
              interaction.isFocused = focused
            }
          }
          session.addressFieldFocusChanged(focused)
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
    // Reveal only the contents inside the animating capsule. The glass is a
    // separate background and keeps its own native rounded edge.
    .mask {
      RoundedRectangle(cornerRadius: AddressCapsuleLayout.cornerRadius,
                       style: .continuous)
    }
    .browserAddressFieldSurface(cornerRadius: AddressCapsuleLayout.cornerRadius)
    .contentShape(Capsule())
    .simultaneousGesture(TapGesture().onEnded {
      if !interaction.isFocused {
        session.requestAddressFieldFocus()
      }
    })
    .overlay {
      GeometryReader { geometry in
        NativeAddressFocusRing(isFocused: interaction.isFocused
                               && session.isEditingAddressField)
          .frame(width: geometry.size.width + NativeAddressFocusRing.inset * 2,
                 height: AddressCapsuleLayout.height + NativeAddressFocusRing.inset * 2)
          .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
      }
      .allowsHitTesting(false)
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

/// AppKit draws the system focus halo around the same capsule that SwiftUI
/// resizes. Keeping the view mounted lets its bounds follow every spring frame.
private struct NativeAddressFocusRing: NSViewRepresentable {
  static let inset: CGFloat = 6

  let isFocused: Bool

  func makeNSView(context: Context) -> FocusRingView {
    let view = FocusRingView()
    view.isFocused = isFocused
    return view
  }

  func updateNSView(_ view: FocusRingView, context: Context) {
    view.isFocused = isFocused
  }

  final class FocusRingView: NSView {
    var isFocused = false {
      didSet {
        if oldValue != isFocused { needsDisplay = true }
      }
    }

    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      guard isFocused else { return }
      NSGraphicsContext.saveGraphicsState()
      NSFocusRingPlacement.only.set()
      let capsule = bounds.insetBy(dx: NativeAddressFocusRing.inset,
                                   dy: NativeAddressFocusRing.inset)
      NSBezierPath(roundedRect: capsule,
                   xRadius: AddressCapsuleLayout.cornerRadius,
                   yRadius: AddressCapsuleLayout.cornerRadius).fill()
      NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
