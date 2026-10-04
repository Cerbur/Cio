import SwiftUI

enum SidebarTabAppearance {
  static let faviconSize: CGFloat = 18
  static let glassShape = RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius, style: .continuous)
}

/// Container-supplied facts. Tabs decide how these facts affect their surface;
/// the movement coordinator does not draw or animate their material.
struct SidebarTabPresentation {
  enum Placement {
    case row
    case liftedRow
    case topPin
    case splitPreview
  }

  var placement = Placement.row
  var isDragged = false
  var isLifted = false
  var preservesGlassContinuity = false
  var grab = CGPoint(x: 0.5, y: 0.5)

  var isFloating: Bool { placement != .row }

  var transition: AnyTransition { preservesGlassContinuity ? .identity : .opacity }
}

private struct SidebarTabPresentationKey: EnvironmentKey {
  static let defaultValue = SidebarTabPresentation()
}

extension EnvironmentValues {
  var sidebarTabPresentation: SidebarTabPresentation {
    get { self[SidebarTabPresentationKey.self] }
    set { self[SidebarTabPresentationKey.self] = newValue }
  }
}

/// Tab-owned glass and hover behavior, shared by ordinary rows, combined
/// tabs, Top Pins and the floating tab that becomes a split-preview card.
struct SidebarTabSurface: ViewModifier {
  var isStable = false
  var isHovered = false
  var idleFill: Double = 0
  var usesScrollEdge = true
  var stableBorderOpacity: Double = 0.35
  var hoverBorderOpacity: Double = 0
  @Environment(\.sidebarTabPresentation) private var presentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var showsGlass: Bool { isStable || presentation.isDragged }

  @ViewBuilder
  func body(content: Content) -> some View {
    if presentation.isFloating {
      content
        .clipShape(SidebarTabAppearance.glassShape)
        .glassEffect(.regular, in: SidebarTabAppearance.glassShape)
        .glassEffectTransition(reduceMotion || presentation.preservesGlassContinuity ? .identity : .materialize)
        .scaleEffect(presentation.isLifted && !reduceMotion ? 1.04 : 1,
                     anchor: UnitPoint(x: presentation.grab.x, y: presentation.grab.y))
        .shadow(color: .black.opacity(presentation.isLifted ? 0.2 : 0.06),
                radius: presentation.isLifted ? 16 : 5, y: presentation.isLifted ? 9 : 2)
        .transition(presentation.transition)
    } else {
      content
        .background {
          if showsGlass {
            Color.clear.browserChromeGlassSurface(in: SidebarTabAppearance.glassShape)
              .modifier(SidebarScrollEdgeSurface(isEnabled: usesScrollEdge))
          } else if isHovered || idleFill > 0 {
            SidebarTabAppearance.glassShape.fill(.primary.opacity(isHovered ? 0.06 : idleFill))
              .modifier(SidebarScrollEdge(isEnabled: usesScrollEdge))
          }
        }
        .overlay {
          if showsGlass || (isHovered && hoverBorderOpacity > 0) {
            SidebarTabAppearance.glassShape.strokeBorder(.white.opacity(showsGlass ? stableBorderOpacity : hoverBorderOpacity), lineWidth: 1)
              .modifier(SidebarScrollEdge(isEnabled: usesScrollEdge))
          }
        }
    }
  }
}
