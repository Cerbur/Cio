import CioEngine
import SwiftUI

enum SidebarTabAppearance {
  static let faviconSize = BrowserLayout.sidebarTabIconSize
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
  /// Sidebar pickup moves the existing-looking object without restyling it.
  var preservesLiftAppearance = false
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
        // Keep the label inside the native glass effect's foreground. A
        // separate background effect in GlassEffectContainer samples the
        // detached label as backdrop, blurring it beneath the glass surface.
        // The native effect also owns the edge; another stroke doubles it.
        .glassEffect(.regular, in: SidebarTabAppearance.glassShape)
        .glassEffectTransition(reduceMotion || presentation.preservesGlassContinuity ? .identity : .materialize)
        .scaleEffect(presentation.preservesLiftAppearance
                     ? (presentation.placement == .topPin && isStable ? AnimationValues.Sidebar.selectedTopPinScale : 1)
                     : (presentation.isLifted && !reduceMotion ? AnimationValues.TabDrag.liftedScale : 1),
                     anchor: presentation.preservesLiftAppearance
                       ? .center : UnitPoint(x: presentation.grab.x, y: presentation.grab.y))
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

/// Tabs and Spaces are presentations of the same row. Keep the primary control
/// full-width and retain its trailing action in one fixed slot, independent of
/// the native button/menu's intrinsic dimensions.
struct SidebarRowContainer<Primary: View, Action: View>: View {
  var showsAction: Bool
  var actionWidth = BrowserLayout.sidebarTabCloseButtonWidth
  var trailingInset = BrowserLayout.sidebarTabTrailingInset
  @ViewBuilder let primary: () -> Primary
  @ViewBuilder let action: () -> Action

  var body: some View {
    ZStack(alignment: .trailing) {
      primary()
        .padding(.trailing, showsAction ? actionWidth : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      action()
        .frame(width: actionWidth)
        .frame(maxHeight: .infinity)
        .opacity(showsAction ? 1 : 0)
        .allowsHitTesting(showsAction)
    }
    .padding(.trailing, trailingInset)
  }
}

/// The same glyph sizing, center and hover feedback for close and menu actions.
struct SidebarRowActionSymbol: View {
  let name: String
  var isHovered = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Image(systemName: name)
      .font(.system(size: BrowserLayout.sidebarTabActionSymbolSize, weight: .semibold))
      .foregroundStyle(isHovered
        ? (colorScheme == .dark ? Color.white : Color.black) : Color.secondary)
      .scaleEffect(isHovered ? AnimationValues.Sidebar.closeButtonHoverScale : 1)
      .animation(reduceMotion ? nil : .easeInOut(duration: AnimationValues.Sidebar.closeButtonHoverDuration),
        value: isHovered)
      .frame(width: BrowserLayout.sidebarTabCloseButtonWidth)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
  }
}

/// Shared icon, title and presentation geometry. A Space only changes title
/// weight and icon content; tab split/card motion keeps its retained labels.
struct SidebarRowLabel<Icon: View>: View, Animatable {
  let title: String
  var titleWeight: Font.Weight = .regular
  nonisolated var compactAmount: CGFloat = 0
  nonisolated var topPinAmount: CGFloat = 0
  nonisolated var cardAmount: CGFloat = 0
  @ViewBuilder let icon: (CGFloat) -> Icon

  nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
    get { AnimatablePair(AnimatablePair(compactAmount, topPinAmount), cardAmount) }
    set {
      compactAmount = newValue.first.first
      topPinAmount = newValue.first.second
      cardAmount = newValue.second
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let compact = min(1, max(0, compactAmount))
      let tile = min(1, max(0, topPinAmount))
      let card = min(1, max(0, cardAmount))
      let centered = min(1, tile + card)
      // Split members keep the ordinary row's favicon size and leading grid.
      let leading = BrowserLayout.sidebarTabLabelInset
      let iconWidth = BrowserLayout.sidebarTabIconSlotWidth
      let spacing = BrowserLayout.sidebarTabLabelSpacing
        + (BrowserLayout.sidebarSplitLabelSpacing - BrowserLayout.sidebarTabLabelSpacing) * compact
      let titleLeading = leading + iconWidth + spacing
      let titleWidth = max(0, geometry.size.width - titleLeading)
      let iconX = leading + iconWidth / 2
      ZStack(alignment: .topLeading) {
        icon(SidebarTabAppearance.faviconSize + 22 * card)
          .position(x: iconX + (geometry.size.width / 2 - iconX) * centered, y: geometry.size.height / 2)
        Text(title)
          .font(.system(size: BrowserLayout.sidebarTabLabelFontSize
            + (BrowserLayout.sidebarSplitLabelFontSize - BrowserLayout.sidebarTabLabelFontSize) * compact,
            weight: titleWeight))
          .lineLimit(1)
          .frame(width: titleWidth, alignment: .leading)
          .position(x: titleLeading + titleWidth / 2, y: geometry.size.height / 2)
          .opacity(1 - centered)
        Text(title)
          .font(.callout.weight(titleWeight))
          .multilineTextAlignment(.center)
          .lineLimit(3)
          .frame(width: max(geometry.size.width - 24, 1), height: max(geometry.size.height * 0.3, 1))
          .position(x: geometry.size.width / 2, y: geometry.size.height * 0.79)
          .opacity(card)
      }
    }
    .accessibilityHidden(true)
  }
}

struct SidebarRetainedTabLabel: View {
  let pageURL: URL?
  let faviconData: Data?
  let session: (any BrowserSessionProtocol)?
  let title: String
  let fallbackLetter: String?
  var compactAmount: CGFloat
  var topPinAmount: CGFloat
  var cardAmount: CGFloat = 0

  var body: some View {
    SidebarRowLabel(title: title, compactAmount: compactAmount,
      topPinAmount: topPinAmount, cardAmount: cardAmount) { size in
      TabFaviconView(pageURL: pageURL, session: session, size: size,
        fallbackLetter: fallbackLetter, cachedData: faviconData)
    }
  }
}
