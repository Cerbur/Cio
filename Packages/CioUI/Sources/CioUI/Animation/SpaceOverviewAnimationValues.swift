import Foundation

extension AnimationValues {
  enum SpaceOverview {
    @MainActor static var response: TimeInterval { AnimationValues.duration(0.44) }
    static let bounce = 0.0
    static let settlingEpsilon = 0.001
    static let widthSettlingEpsilon = 0.1
    // Input sampling is operational time, independent of animation speed.
    static let gestureVelocityLifetime: TimeInterval = 0.12
    static let commitProgress: CGFloat = 0.5
    static let edgeResistance: CGFloat = 0.22
  }
}
