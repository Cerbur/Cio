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

/// Native glass for stable tabs/groups, floating cards and the New Tab action.
/// Top Pins retain their idle fill; split members have no nested backgrounds.
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
        .scaleEffect(presentation.isLifted && !reduceMotion ? AnimationValues.TabDrag.liftedScale : 1,
                     anchor: UnitPoint(x: presentation.grab.x, y: presentation.grab.y))
        .shadow(color: .black.opacity(presentation.isLifted
                  ? AnimationValues.TabDrag.liftedShadowOpacity : AnimationValues.TabDrag.restingShadowOpacity),
                radius: presentation.isLifted
                  ? AnimationValues.TabDrag.liftedShadowRadius : AnimationValues.TabDrag.restingShadowRadius,
                y: presentation.isLifted
                  ? AnimationValues.TabDrag.liftedShadowOffset : AnimationValues.TabDrag.restingShadowOffset)
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

/// Keeps Space and Tab titles, icons and hit areas on the same grid.
struct SidebarRowLabel<Icon: View>: View {
  let title: String
  var selected = false
  @ViewBuilder let icon: () -> Icon

  var body: some View {
    HStack(spacing: BrowserLayout.sidebarTabLabelSpacing) {
      icon().frame(width: BrowserLayout.sidebarTabIconSlotWidth)
      Text(title)
        .font(.callout.weight(selected ? .semibold : .regular))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.leading, BrowserLayout.sidebarTabLabelInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
  }
}

/// Keep one icon and title mounted while a tab contracts into a split member.
/// Numeric label geometry interpolates along the panel's transaction; there is
/// no separate compact text subtree or appearance/disappearance transition.
struct SidebarRetainedTabLabel: View, Animatable {
  let pageURL: URL?
  let session: BrowserSession?
  let title: String
  let fallbackLetter: String?
  let selected: Bool
  nonisolated var compactAmount: CGFloat
  nonisolated var topPinAmount: CGFloat

  nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(compactAmount, topPinAmount) }
    set {
      compactAmount = newValue.first
      topPinAmount = newValue.second
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let compact = min(1, max(0, compactAmount))
      let tile = min(1, max(0, topPinAmount))
      let leading = BrowserLayout.sidebarTabLabelInset
        + (BrowserLayout.sidebarSplitLabelInset - BrowserLayout.sidebarTabLabelInset) * compact
      let iconWidth = BrowserLayout.sidebarTabIconSlotWidth
        + (BrowserLayout.sidebarSplitIconSlotWidth - BrowserLayout.sidebarTabIconSlotWidth) * compact
      let spacing = BrowserLayout.sidebarTabLabelSpacing
        + (BrowserLayout.sidebarSplitLabelSpacing - BrowserLayout.sidebarTabLabelSpacing) * compact
      let titleLeading = leading + iconWidth + spacing
      let titleWidth = max(0, geometry.size.width - titleLeading)
      let iconX = leading + iconWidth / 2
      ZStack(alignment: .topLeading) {
        TabFaviconView(pageURL: pageURL, session: session,
          size: SidebarTabAppearance.faviconSize
            + (BrowserLayout.sidebarSplitIconSize - SidebarTabAppearance.faviconSize) * compact * (1 - tile),
          fallbackLetter: fallbackLetter)
          .position(x: iconX + (geometry.size.width / 2 - iconX) * tile, y: geometry.size.height / 2)
        Text(title)
          .font(.system(size: BrowserLayout.sidebarTabLabelFontSize
            + (BrowserLayout.sidebarSplitLabelFontSize - BrowserLayout.sidebarTabLabelFontSize) * compact,
            weight: selected ? .semibold : .regular))
          .lineLimit(1)
          .frame(width: titleWidth, alignment: .leading)
          .position(x: titleLeading + titleWidth / 2, y: geometry.size.height / 2)
          .opacity(1 - tile)
      }
    }
    .accessibilityHidden(true)
  }
}
