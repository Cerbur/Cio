//
//  ToolbarAddressFieldView.swift
//  NativeBrowser
//
//  The toolbar's address capsule: the tab favicon, native address field,
//  reload/stop control, and the capsule glass that carries the focus ring.
//
//  BrowserToolbarController positions this view above the Chromium view;
//  the capsule's appearance and editing behavior live here.
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
  static let reloadHitDiameter: CGFloat = 16
  static let textIdealHeight: CGFloat = 22
  /// Reserve matching space at both ends so idle text is centred in the pill.
  static let endControlWidth: CGFloat = 40
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
  }

  private func addressField(for session: BrowserSession, width: CGFloat) -> some View {
    ZStack {
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
      .frame(width: max(0, width - 2 * AddressCapsuleLayout.endControlWidth),
             height: AddressCapsuleLayout.textIdealHeight)
      .contentShape(Rectangle())
      .allowsHitTesting(true)

      TabFaviconView(pageURL: session.url ?? workspace.selectedTab?.url,
                     session: session, size: AddressCapsuleLayout.faviconSize)
        .frame(width: AddressCapsuleLayout.endControlWidth,
               height: AddressCapsuleLayout.height)
        .contentShape(Rectangle())
        .onTapGesture { session.requestAddressFieldFocus() }
        .accessibilityHidden(true)
        .position(x: AddressCapsuleLayout.cornerRadius,
                  y: AddressCapsuleLayout.height / 2)

      AddressReloadButton(session: session)
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

/// A continuous loading rotation finishes its current turn after CEF reports
/// completion (or the user stops it). The idle image always rests upright.
private struct AddressReloadButton: View {
  @ObservedObject var session: BrowserSession
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var rotation = AddressReloadRotation()
  @State private var isHovered = false

  var body: some View {
    Button {
      if session.isLoading {
        rotation.finish(at: Date(), reduceMotion: reduceMotion)
        session.stop()
      } else {
        session.reload()
      }
    } label: {
      TimelineView(.animation) { context in
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: 11, weight: .semibold))
          .rotationEffect(.degrees(rotation.angle(at: context.date, reduceMotion: reduceMotion)))
          .frame(width: AddressCapsuleLayout.reloadHitDiameter,
                 height: AddressCapsuleLayout.reloadHitDiameter)
          .background {
            Circle().fill(isHovered ? Color.primary.opacity(0.14) : .clear)
          }
          .contentShape(Circle())
      }
    }
    .buttonStyle(.plain)
    .onHover { hovered in
      withAnimation(.easeOut(duration: 0.15)) { isHovered = hovered }
    }
    .help(session.isLoading ? "Stop" : "Reload")
    .accessibilityLabel(session.isLoading ? "Stop" : "Reload")
    .onAppear {
      if session.isLoading { rotation.start(at: Date(), reduceMotion: reduceMotion) }
    }
    .onChange(of: session.isLoading) { _, isLoading in
      if isLoading {
        rotation.start(at: Date(), reduceMotion: reduceMotion)
      } else {
        rotation.finish(at: Date(), reduceMotion: reduceMotion)
      }
    }
  }
}

@MainActor
private final class AddressReloadRotation: ObservableObject {
  @Published private var spinStartedAt: Date?
  @Published private var finishStartedAt: Date?
  @Published private var finishAngle: Double = 0

  private let turnDuration: TimeInterval = 0.9

  func angle(at date: Date, reduceMotion: Bool) -> Double {
    if reduceMotion { return 0 }
    if let spinStartedAt {
      return (date.timeIntervalSince(spinStartedAt) / turnDuration * 360)
        .truncatingRemainder(dividingBy: 360)
    }
    if let finishStartedAt {
      let elapsed = date.timeIntervalSince(finishStartedAt)
      let remaining = 360 - finishAngle
      return elapsed >= remaining / 360 * turnDuration
        ? 0 : finishAngle + elapsed / turnDuration * 360
    }
    return 0
  }

  func start(at date: Date, reduceMotion: Bool) {
    spinStartedAt = reduceMotion ? nil : date
    finishStartedAt = nil
  }

  func finish(at date: Date, reduceMotion: Bool) {
    guard let spinStartedAt else { return }
    finishAngle = (date.timeIntervalSince(spinStartedAt) / turnDuration * 360)
      .truncatingRemainder(dividingBy: 360)
    self.spinStartedAt = nil
    finishStartedAt = reduceMotion ? nil : date
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
