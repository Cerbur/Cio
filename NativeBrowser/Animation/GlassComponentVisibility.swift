import SwiftUI

/// Apply to the complete first-level component after composing native glass and
/// content. Materialize owns the glass effect; do not fade its parent to zero.
struct GlassComponentVisibility: ViewModifier {
  let isVisible: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.scaleEffect(isVisible || reduceMotion ? 1 : AnimationValues.GlassComponent.dispersedScale)
  }
}

/// Apply to the retained content before adding its native glass background.
/// Only content blurs; system materialize controls the glass's optical changes.
struct GlassComponentContentVisibility: ViewModifier {
  let isVisible: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .blur(radius: isVisible || reduceMotion ? 0 : AnimationValues.GlassComponent.contentBlurRadius)
      .opacity(isVisible ? 1 : 0)
  }
}
