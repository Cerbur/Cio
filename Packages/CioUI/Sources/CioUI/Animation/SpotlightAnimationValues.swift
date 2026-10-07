import Foundation

extension AnimationValues {
  /// 新标签页玻璃展开 / 收起和建议列表扩张；延迟与宿主移除也按速度缩放。
  enum Spotlight {
    @MainActor static var suggestionsResponse: TimeInterval { AnimationValues.duration(0.32) }
    @MainActor static var revealResponse: TimeInterval { AnimationValues.duration(0.31) }
    @MainActor static var revealFadeDuration: TimeInterval { AnimationValues.duration(0.12) }
    @MainActor static var reducedMotionRevealDuration: TimeInterval { AnimationValues.duration(0.08) }
    @MainActor static var contentRevealDelay: TimeInterval { AnimationValues.duration(0.067) }
    @MainActor static var contentDismissDuration: TimeInterval { AnimationValues.duration(0.025) }
    @MainActor static var glassDismissDuration: TimeInterval { AnimationValues.duration(0.13) }
    @MainActor static var dismissFadeDuration: TimeInterval { AnimationValues.duration(0.03) }
    @MainActor static var dismissFadeDelay: TimeInterval { AnimationValues.duration(0.1) }
    @MainActor static var retirementDuration: TimeInterval { AnimationValues.duration(0.17) }
    static let suggestionsDamping = 0.86
    static let revealDamping = 0.68
    static let collapsedGlassDiameter: CGFloat = 34
    static let collapsedGlassOffset: CGFloat = 16
  }
}
