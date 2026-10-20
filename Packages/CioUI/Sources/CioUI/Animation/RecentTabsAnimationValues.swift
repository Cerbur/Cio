import Foundation
import CoreGraphics

extension AnimationValues {
  enum RecentTabs {
    @MainActor static var visibilityDuration: TimeInterval { AnimationValues.duration(0.14) }
    /// Clear preview/card edges before the material finishes dispersing.
    @MainActor static var contentDismissDuration: TimeInterval { AnimationValues.duration(0.055) }
    static let blurOutsetMultiplier: CGFloat = 3

    /// The native window is a render envelope, not the glass's resting bounds.
    /// Leave room for both shared dispersion and the blur's sample footprint.
    static var blurOutset: CGFloat { GlassComponent.contentBlurRadius * blurOutsetMultiplier }
    static func renderInset(for size: CGSize) -> CGFloat {
      ceil(max(size.width, size.height) * (GlassComponent.dispersedScale - 1) / 2 + blurOutset)
    }
  }
}
