import Foundation

extension AnimationValues {
  /// Shared Liquid Glass component motion. Standard pace; geometry is speed independent.
  enum GlassComponent {
    @MainActor static var visibilityDuration: TimeInterval { AnimationValues.duration(0.25) }
    @MainActor static var positionResponse: TimeInterval { AnimationValues.duration(0.195) }
    @MainActor static var sizeResponse: TimeInterval { AnimationValues.duration(0.26) }
    static let positionBounce = 0.0
    static let sizeBounce = 0.22
    static let dispersedScale: CGFloat = 1.12
    static let contentBlurRadius: CGFloat = 5
    static let sampleCount = 120
    static let settlingEpsilon = 0.001
    static let minimumDimension: CGFloat = 0.001
  }
}
