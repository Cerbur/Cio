import SwiftUI

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
