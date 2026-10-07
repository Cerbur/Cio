import Combine
import Foundation

enum BrowserAnimationSpeed: String, CaseIterable, Identifiable {
  case detailed
  case standard
  case fast

  var id: String { rawValue }

  var title: String {
    switch self {
    case .detailed: "细腻"
    case .standard: "标准"
    case .fast: "快速"
    }
  }

  /// Scale elapsed time, including springs, rather than changing their shape.
  var durationMultiplier: Double {
    switch self {
    case .detailed: AnimationValues.Speed.detailedDurationMultiplier
    case .standard: AnimationValues.Speed.standardDurationMultiplier
    case .fast: AnimationValues.Speed.fastDurationMultiplier
    }
  }

  var sliderPosition: Double {
    Double(Self.allCases.firstIndex(of: self) ?? 1)
  }

  init(sliderPosition: Double) {
    let index = min(Self.allCases.count - 1, max(0, Int(sliderPosition.rounded())))
    self = Self.allCases[index]
  }
}

/// 整个 Animation 包共享的持久化速度偏好。
/// 比例定义在 AnimationValues.Speed，时间换算在 AnimationValues.duration；
/// UI 组件只使用命名动画参数，不直接访问比例或在本地换算秒数。
@MainActor
final class BrowserAnimationPreferences: ObservableObject {
  static let shared = BrowserAnimationPreferences()
  static let speedPreferenceKey = "browser.animationSpeed"

  private let defaults: UserDefaults
  @Published var speed: BrowserAnimationSpeed {
    didSet { defaults.set(speed.rawValue, forKey: Self.speedPreferenceKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    speed = defaults.string(forKey: Self.speedPreferenceKey)
      .flatMap(BrowserAnimationSpeed.init(rawValue:)) ?? .standard
  }
}
