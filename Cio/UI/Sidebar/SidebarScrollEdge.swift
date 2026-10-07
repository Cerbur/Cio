import SwiftUI

/// Blur the scrolling foreground itself. Native glass stays out of the Metal
/// layer and receives a standard SwiftUI blur in SidebarScrollEdgeSurface.
struct SidebarScrollEdge: ViewModifier {
  static let coordinateSpace = "sidebar-space-scroll-edge"
  var isEnabled = true

  func body(content: Content) -> some View {
    content.visualEffect { effect, geometry in
      let origin = geometry.frame(in: .named(Self.coordinateSpace)).minY
        - BrowserLayout.sidebarScrollHiddenBoundary
      let height = BrowserLayout.sidebarScrollTransitionHeight
      let radius = BrowserLayout.sidebarScrollBlurRadius
      let active = isEnabled && origin < height
      return effect
        .layerEffect(ShaderLibrary.sidebarScrollEdgeBlur(
          .float(origin), .float(height), .float(radius), .float2(1, 0)),
          maxSampleOffset: CGSize(width: radius, height: 0), isEnabled: active)
        .layerEffect(ShaderLibrary.sidebarScrollEdgeBlur(
          .float(origin), .float(height), .float(radius), .float2(0, 1)),
          maxSampleOffset: CGSize(width: 0, height: radius), isEnabled: active)
    }
  }
}

/// Use the system blur for live glass rather than feeding an AppKit-backed
/// material into a Metal shader. The whole row shares the spatial fade below.
struct SidebarScrollEdgeSurface: ViewModifier {
  var isEnabled = true

  func body(content: Content) -> some View {
    content.visualEffect { effect, geometry in
      let y = geometry.frame(in: .named(SidebarScrollEdge.coordinateSpace)).midY
      let progress = min(max((y - BrowserLayout.sidebarScrollHiddenBoundary)
                            / BrowserLayout.sidebarScrollTransitionHeight, 0), 1)
      let strength = 1 - progress * progress * progress * (progress * (progress * 6 - 15) + 10)
      return effect.blur(radius: isEnabled ? BrowserLayout.sidebarScrollBlurRadius * strength : 0)
    }
  }
}

/// One viewport mask fades all scrolling surfaces, including live glass.
/// The fixed header sits outside this mask. Stops follow the transition's
/// actual points, rather than spreading a few samples across the whole list.
struct SidebarScrollEdgeFade: ViewModifier {
  func body(content: Content) -> some View {
    content.mask {
      GeometryReader { geometry in
        let origin = geometry.frame(in: .named(SidebarScrollEdge.coordinateSpace)).minY
        let height = max(geometry.size.height, 1)
        let boundary = BrowserLayout.sidebarScrollHiddenBoundary
        let fadeHeight = BrowserLayout.sidebarScrollFadeHeight
        let locations = ([CGFloat(0)] + (0...32).map {
          min(max((boundary + fadeHeight * CGFloat($0) / 32 - origin) / height, 0), 1)
        } + [CGFloat(1)]).sorted()
        let stops: [Gradient.Stop] = locations.map { location in
          let progress = min(max((origin + height * location - boundary) / fadeHeight, 0), 1)
          let opacity = progress * progress * progress * (progress * (progress * 6 - 15) + 10)
          return .init(color: .black.opacity(Double(opacity)), location: location)
        }
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
      }
    }
  }
}
