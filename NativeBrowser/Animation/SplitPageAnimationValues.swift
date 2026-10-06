import Foundation

extension AnimationValues {
  /// 已调好的分屏展开、消失、挤压与黄灯收起节奏。标准档保持原视觉效果。
  /// 时长已缩放；中点、淡出区间和贝塞尔控制点均是归一化进度，不做缩放。
  enum SplitPages {
    static let cardSize = CGSize(width: 140, height: 196)
    @MainActor static var enterDuration: TimeInterval { AnimationValues.duration(0.36) }
    @MainActor static var exitDuration: TimeInterval { AnimationValues.duration(0.165) }
    @MainActor static var layoutDuration: TimeInterval { AnimationValues.duration(0.195) }
    @MainActor static var contentFadeDuration: TimeInterval { AnimationValues.duration(0.135) }
    @MainActor static var contentWaitDuration: TimeInterval { AnimationValues.duration(0.75) }
    @MainActor static var handleDuration: TimeInterval { AnimationValues.duration(0.2) }

    static let sidebarDetachFraction = 0.5
    static let dismissScale: CGFloat = 0.94
    static let sampleCount = 120
    static let bezierIterations = 20
    static let minimumScale: CGFloat = 0.001
    static let glassHoldFraction = 0.08
    static let glassFadeFraction = 0.92
    static let enterEasing: (Float, Float, Float, Float) = (0.32, 0, 0.2, 1)
    static let layoutEasing: (Float, Float, Float, Float) = (0.18, 0.78, 0.24, 1)
    static let exitEasing: (Float, Float, Float, Float) = (0.3, 0, 0.65, 1)
    static let sidebarGlassFadeStart: CGFloat = 0.9
    static let sidebarGlassFadeSpan: CGFloat = 0.1
    static let sidebarLabelFadeStart: CGFloat = 0.68
    static let sidebarLabelFadeSpan: CGFloat = 0.28
    // 小于一个采样间隔的落点校正无需再启动一次动画。
    @MainActor static var minimumCorrectionDuration: TimeInterval { AnimationValues.duration(1.0 / 120) }
  }
}
