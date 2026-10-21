import SwiftUI

/// Interpolate the reveal clock, then derive alpha from its presentation value.
/// A plain opacity animation fades sparse tab labels before their upward travel
/// is visible, especially when combined with the header's spatial fade/blur.
struct SpacePinVisibilityMotion: ViewModifier, Animatable {
  nonisolated var hiddenProgress: CGFloat

  init(isHidden: Bool) {
    hiddenProgress = isHidden ? 1 : 0
  }

  nonisolated var animatableData: CGFloat {
    get { hiddenProgress }
    set { hiddenProgress = newValue }
  }

  func body(content: Content) -> some View {
    content.opacity(AnimationValues.Sidebar.spacePinOpacity(hiddenProgress: hiddenProgress))
  }
}
