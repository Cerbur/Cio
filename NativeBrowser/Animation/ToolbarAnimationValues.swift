import Foundation

extension AnimationValues {
  /// 工具栏一级控件的出现 / 消失；销毁等待与消失动画使用同一个速度比例。
  enum Toolbar {
    @MainActor static var visibilityDuration: TimeInterval { AnimationValues.duration(0.25) }
    @MainActor static var retirementGraceDuration: TimeInterval { AnimationValues.duration(0.05) }
    static let dispersedScale: CGFloat = 1.12

    @MainActor static var retirementDuration: TimeInterval { visibilityDuration + retirementGraceDuration }
  }
}
