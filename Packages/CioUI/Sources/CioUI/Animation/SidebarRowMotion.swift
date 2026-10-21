import SwiftUI

/// Translate with an affine geometry effect. Ordinary reordering keeps
/// the row's size and visibility unchanged, so it must not evaluate a custom
/// five-scalar modifier and relayout native controls on every display frame.
struct SidebarRowMotion: ViewModifier {
  let frame: CGRect
  var isHidden = false

  func body(content: Content) -> some View {
    content
      .modifier(SidebarRowSizeMotion(size: frame.size))
      .modifier(SidebarPinVisibilityMotion(hiddenProgress: isHidden ? 1 : 0))
      .modifier(SidebarRowTranslationMotion(origin: frame.origin))
  }
}

/// Update only the render transform, while reporting presentation geometry to
/// the retained drag registrations. A plain offset reports its final geometry
/// immediately; row targeting and native landing need the intermediate frames.
private struct SidebarRowTranslationMotion: GeometryEffect {
  nonisolated var origin: CGPoint

  nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { .init(origin.x, origin.y) }
    set { origin = CGPoint(x: newValue.first, y: newValue.second) }
  }

  nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: origin.x, y: origin.y))
  }
}

/// Only splitting/grouping/resizing changes layout dimensions. Preserve the
/// native control and its text layout; never scale a rendered row or its glass.
private struct SidebarRowSizeMotion: ViewModifier, Animatable {
  nonisolated var size: CGSize

  nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { .init(size.width, size.height) }
    set {
      size = CGSize(width: newValue.first, height: newValue.second)
    }
  }

  func body(content: Content) -> some View {
    content.frame(width: max(0, size.width), height: max(0, size.height))
  }
}

/// The nonlinear fade is active only for Pin reveal/collapse, independently of
/// ordinary position changes. Keep the late fade that preserves upward travel.
private struct SidebarPinVisibilityMotion: ViewModifier, Animatable {
  nonisolated var hiddenProgress: CGFloat

  nonisolated var animatableData: CGFloat {
    get { hiddenProgress }
    set { hiddenProgress = newValue }
  }

  func body(content: Content) -> some View {
    content.opacity(AnimationValues.Sidebar.spacePinOpacity(hiddenProgress: hiddenProgress))
  }
}

/// Reflow the surrounding stack on the same clock as its rows. In particular,
/// a Top Pin reservation must push the fixed Space header and its viewport on
/// every presentation frame rather than jumping them to the final height.
struct SidebarPanelHeightMotion: ViewModifier, Animatable {
  nonisolated var height: CGFloat

  nonisolated var animatableData: CGFloat {
    get { height }
    set { height = newValue }
  }

  func body(content: Content) -> some View {
    content.frame(height: max(0, height), alignment: .top)
  }
}

extension View {
  /// Each retained piece of a row (surface, decoration and native members)
  /// receives the same container clock. Local animation survives geometry-only
  /// updates and cannot be cancelled by a descendant's source-opacity policy.
  func sidebarRowMotion(frame: CGRect, isHidden: Bool = false, hiddenTabIDs: Set<UUID>,
                        animation: Animation?, revealAnimation: Animation?) -> some View {
    modifier(SidebarRowMotion(frame: frame, isHidden: isHidden))
      // The reveal transaction takes precedence on both edges, including the
      // visible rows displaced by hidden pins. Other moves use the drag clock.
      .animation(revealAnimation, value: hiddenTabIDs)
      .animation(animation, value: frame)
  }
}
