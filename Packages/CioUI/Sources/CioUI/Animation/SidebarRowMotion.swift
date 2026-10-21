import SwiftUI

/// Own presentation geometry resolved by the panel's GeometryReader. A layout
/// pass may replace its target frames without carrying the parent's animation
/// transaction into the reader's children. Animate the container itself, not
/// the native controls, labels or split decorations inside it.
struct SidebarRowMotion: ViewModifier, Animatable {
  nonisolated var frame: CGRect
  nonisolated var hiddenProgress: CGFloat

  init(frame: CGRect, isHidden: Bool = false) {
    self.frame = frame
    hiddenProgress = isHidden ? 1 : 0
  }

  nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
    AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
    get {
      .init(.init(frame.origin.x, frame.origin.y),
            .init(.init(frame.width, frame.height), hiddenProgress))
    }
    set {
      frame = CGRect(x: newValue.first.first, y: newValue.first.second,
                     width: newValue.second.first.first, height: newValue.second.first.second)
      hiddenProgress = newValue.second.second
    }
  }

  func body(content: Content) -> some View {
    content
      .frame(width: max(0, frame.width), height: max(0, frame.height))
      .opacity(AnimationValues.Sidebar.spacePinOpacity(hiddenProgress: hiddenProgress))
      .offset(x: frame.minX, y: frame.minY)
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
    content.frame(height: max(0, height))
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
