import Foundation

extension AnimationValues {
  /// 侧栏浮块的托起、变形、排序、落点与交接；与分屏页面动画共用速度设置。
  enum TabDrag {
    @MainActor static var liftDuration: TimeInterval { AnimationValues.duration(0.2) }
    @MainActor static var liftResponse: TimeInterval { AnimationValues.duration(0.3) }
    @MainActor static var morphResponse: TimeInterval { AnimationValues.duration(0.3) }
    @MainActor static var reorderDuration: TimeInterval { AnimationValues.duration(0.28) }
    @MainActor static var targetDuration: TimeInterval { AnimationValues.duration(0.26) }
    @MainActor static var landingResponse: TimeInterval { AnimationValues.duration(0.34) }
    @MainActor static var handoffDuration: TimeInterval { AnimationValues.duration(0.18) }
    @MainActor static var landingFrameWaitDuration: TimeInterval { AnimationValues.duration(0.15) }
    static let liftDamping = 0.68
    static let morphDamping = 0.78
    static let landingDamping = 0.84
    static let liftedScale: CGFloat = 1.04
    static let liftedShadowOpacity = 0.2
    static let restingShadowOpacity = 0.06
    static let liftedShadowRadius: CGFloat = 16
    static let restingShadowRadius: CGFloat = 5
    static let liftedShadowOffset: CGFloat = 9
    static let restingShadowOffset: CGFloat = 2
  }
}
