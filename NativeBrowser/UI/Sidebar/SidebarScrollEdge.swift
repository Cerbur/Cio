import AppKit
import SwiftUI

/// Sits above the Space scroll view, but below the fixed Top Pins. The blur is
/// drawn by the rows; this layer prevents interaction with their obscured parts.
struct SidebarScrollEdgeShield: NSViewRepresentable {
  func makeNSView(context: Context) -> ShieldView { ShieldView() }
  func updateNSView(_ nsView: ShieldView, context: Context) {}

  final class ShieldView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
      // Let AppKit deliver wheel and trackpad events to the scroll view below.
      if NSApp.currentEvent?.type == .scrollWheel { return nil }
      return super.hitTest(point)
    }

    // Consume all mouse buttons rather than forwarding them to row controls or
    // the sidebar's drag gesture through the responder chain.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
  }
}

/// A progressive blur of the scrolling row itself, beneath the fixed Top Pins.
/// Outside this band, native glass remains live rather than being rasterized.
struct SidebarScrollEdge: ViewModifier {
  var isEnabled = true
  func body(content: Content) -> some View {
    content.visualEffect { effect, geometry in
      let originY = geometry.frame(in: .scrollView(axis: .vertical)).minY
      let height = BrowserLayout.sidebarScrollTransitionHeight
      let radius = BrowserLayout.sidebarScrollBlurRadius
      let isInTransition = isEnabled && originY < height
      return effect
        .layerEffect(ShaderLibrary.sidebarScrollEdgeBlur(
          .float(originY), .float(height), .float(radius), .float2(1, 0)),
          maxSampleOffset: CGSize(width: radius, height: 0), isEnabled: isInTransition)
        .layerEffect(ShaderLibrary.sidebarScrollEdgeBlur(
          .float(originY), .float(height), .float(radius), .float2(0, 1)),
          maxSampleOffset: CGSize(width: 0, height: radius), isEnabled: isInTransition)
    }
  }
}

/// Fade the live glass surface as its foreground disappears into the pins.
struct SidebarScrollEdgeFade: ViewModifier {
  var isEnabled = true

  func body(content: Content) -> some View {
    content.visualEffect { effect, geometry in
      let y = geometry.frame(in: .scrollView(axis: .vertical)).midY
      let height = BrowserLayout.sidebarScrollTransitionHeight
      let progress = min(max(y / height, 0), 1)
      return effect.opacity(isEnabled ? progress * progress * (3 - 2 * progress) : 1)
    }
  }
}
