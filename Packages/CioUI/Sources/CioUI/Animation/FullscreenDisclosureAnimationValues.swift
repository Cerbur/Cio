import Foundation

extension AnimationValues {
  enum FullscreenDisclosure {
    private static let blurOutsetMultiplier: CGFloat = 3
    static func drawingOutset(for size: CGSize) -> CGFloat {
      ceil(max(size.width, size.height) * (GlassComponent.dispersedScale - 1) / 2
           + GlassComponent.contentBlurRadius * blurOutsetMultiplier)
    }
    @MainActor static var holdDuration: TimeInterval { AnimationValues.duration(2) }
    @MainActor static var visibilityDuration: TimeInterval { GlassComponent.visibilityDuration }
    @MainActor static var retirementDuration: TimeInterval { Toolbar.retirementDuration }
  }
}
