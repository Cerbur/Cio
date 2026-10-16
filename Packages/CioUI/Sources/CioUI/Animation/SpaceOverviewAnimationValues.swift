import Foundation

extension AnimationValues {
  enum SpaceOverview {
    @MainActor static var response: TimeInterval { AnimationValues.duration(0.34) }
    static let bounce = 0.0
    static let settlingEpsilon = 0.01
    static let edgeResistance: CGFloat = 0.22
  }
}
