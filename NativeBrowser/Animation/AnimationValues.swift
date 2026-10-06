import Foundation

/// 应用自定义窗口 / UI 动画参数的唯一入口。
/// 新增效果请在 Animation 包中按组件扩展此命名空间；禁止在 UI 组件中
/// 直接填写时长、延迟、spring response、阻尼、曲线或其他速度相关调参值。
/// 所有时间属性已经乘以设置中的速度比例，调用方直接引用，不要再次缩放。
/// 曲线、阻尼与几何值不随速度变化；系统原生动画和事件调度不由此接管。
enum AnimationValues {
  /// 标准档秒数 → 当前档秒数。仅参数文件可以调用，组件使用命名属性。
  /// 每次开始动画时读取；需要后续清理的效果应捕获该次时间，保持同一时钟。
  @MainActor
  static func duration(_ standardSeconds: TimeInterval) -> TimeInterval {
    standardSeconds * BrowserAnimationPreferences.shared.speed.durationMultiplier
  }

  enum Speed {
    static let detailedDurationMultiplier = 4.0 / 3.0
    static let standardDurationMultiplier = 1.0
    static let fastDurationMultiplier = 2.0 / 3.0
  }
}
