//
//  ToolbarAddressFieldView.swift
//  NativeBrowser
//
//  The toolbar's address capsule: the tab favicon, native address field,
//  reload/stop control, and the capsule glass that carries the focus ring.
//
//  BrowserToolbarController positions this view above the Chromium view;
//  the capsule's appearance lives here, while toolbar events own its focus state.
//

import AppKit
import SwiftUI

/// Geometry of the address capsule.
///
/// The corner radius is half the height, making each end of the pill a circle.
/// The favicon and reload icon sit on the respective cap centres.
enum AddressCapsuleLayout {
  static let height: CGFloat = 36
  static let cornerRadius = height / 2
  static let unfocusedWidthRatio: CGFloat = 0.38
  static let focusedWidthRatio: CGFloat = 0.45
  static let faviconSize: CGFloat = 16
  static let reloadHitDiameter: CGFloat = 18
  static let textIdealHeight: CGFloat = 22
  /// Reserve matching space at both ends so idle text is centred in the pill.
  static let endControlWidth: CGFloat = 40
}

struct ToolbarAddressFieldView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  @ObservedObject var interaction: BrowserInteractionState
  var onFocusChange: (BrowserSession, Bool) -> Void
  var onReloadOrStop: (BrowserSession) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let isFocused = interaction.isFocused
      let widthRatio = isFocused
        ? 1 : AddressCapsuleLayout.unfocusedWidthRatio / AddressCapsuleLayout.focusedWidthRatio
      let capsuleWidth = geometry.size.width * widthRatio
      Group {
        if let session = workspace.selectedSession {
          addressField(for: session, width: capsuleWidth)
        } else {
          Color.clear
            .accessibilityHidden(true)
        }
      }
      .frame(width: capsuleWidth,
             height: AddressCapsuleLayout.height)
      .frame(width: geometry.size.width, height: AddressCapsuleLayout.height)
    }
    .frame(height: AddressCapsuleLayout.height)
    .animation(reduceMotion ? nil : .spring(response: 0.31, dampingFraction: 0.68),
               value: interaction.isFocused)
  }

  private func addressField(for session: BrowserSession, width: CGFloat) -> some View {
    ZStack {
      AddressField(
        model: session.addressField,
        isFocused: interaction.isFocused,
        onChange: { session.addressField.userChangedText($0) },
        onSubmit: { session.submitAddressField() },
        onEscape: { session.cancelAddressEditing() },
        onReloadOrStop: { onReloadOrStop(session) },
        onFocusChange: { onFocusChange(session, $0) }
      )
      .frame(width: max(0, width - 2 * AddressCapsuleLayout.endControlWidth),
             height: AddressCapsuleLayout.textIdealHeight)
      .contentShape(Rectangle())
      .allowsHitTesting(true)

      TabFaviconView(pageURL: session.url ?? workspace.selectedTab?.url,
                     session: session, size: AddressCapsuleLayout.faviconSize)
        .frame(width: AddressCapsuleLayout.endControlWidth,
               height: AddressCapsuleLayout.height)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .position(x: AddressCapsuleLayout.cornerRadius,
                  y: AddressCapsuleLayout.height / 2)

      AddressReloadButton(session: session, onReloadOrStop: { onReloadOrStop(session) })
        .id(session.id)
        .frame(width: AddressCapsuleLayout.reloadHitDiameter,
               height: AddressCapsuleLayout.reloadHitDiameter)
        .position(x: width - AddressCapsuleLayout.cornerRadius,
                  y: AddressCapsuleLayout.height / 2)
    }
    .frame(width: width, height: AddressCapsuleLayout.height)
    // Reveal only the contents inside the animating capsule. The glass is a
    // separate background and keeps its own native rounded edge.
    .mask {
      RoundedRectangle(cornerRadius: AddressCapsuleLayout.cornerRadius,
                       style: .continuous)
    }
    .browserAddressFieldSurface(cornerRadius: AddressCapsuleLayout.cornerRadius)
    .contentShape(Capsule())
    .overlay {
      GeometryReader { geometry in
        NativeAddressFocusRing(isFocused: interaction.isFocused)
          .frame(width: geometry.size.width + NativeAddressFocusRing.inset * 2,
                 height: AddressCapsuleLayout.height + NativeAddressFocusRing.inset * 2)
          .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
      }
      .allowsHitTesting(false)
    }
  }
}

/// Loading state comes from the selected session; the idle symbol rests upright.
private struct AddressReloadButton: View {
  @ObservedObject var session: BrowserSession
  var onReloadOrStop: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var rotationStart = Date()
  @State private var isHovered = false

  var body: some View {
    Button(action: onReloadOrStop) {
      Group {
        if session.isLoading && !reduceMotion {
          TimelineView(.animation) { context in
            reloadSymbol
              .rotationEffect(.degrees(
                context.date.timeIntervalSince(rotationStart) / 0.9 * 360))
          }
        } else {
          reloadSymbol
        }
      }
      .frame(width: AddressCapsuleLayout.reloadHitDiameter,
             height: AddressCapsuleLayout.reloadHitDiameter)
      .background {
        Circle().fill(isHovered ? Color.primary.opacity(0.14) : .clear)
      }
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovered in
      withAnimation(.easeOut(duration: 0.15)) { isHovered = hovered }
    }
    .help(session.isLoading ? "Stop" : "Reload")
    .accessibilityLabel(session.isLoading ? "Stop" : "Reload")
    .onChange(of: session.isLoading) { _, isLoading in
      if isLoading { rotationStart = Date() }
    }
  }

  private var reloadSymbol: some View {
    Image(systemName: "arrow.triangle.2.circlepath")
      .font(.system(size: 16, weight: .semibold))
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
