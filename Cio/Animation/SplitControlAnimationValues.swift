import Foundation

extension AnimationValues {
  /// 分屏到位后的操作提示，以及热区内的悬停反馈。
  enum SplitControl {
    @MainActor static var revealDuration: TimeInterval { AnimationValues.duration(0.16) }
    @MainActor static var hoverDuration: TimeInterval { AnimationValues.duration(0.13) }
    static let easing: (Float, Float, Float, Float) = (0.25, 0.1, 0.25, 1)
    static let dividerHoverScale: CGFloat = 1.2
    static let handleHoverScale: CGFloat = 1.14
    static let dividerIdleOpacity: CGFloat = 0.35
  }
}
