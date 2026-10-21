import Foundation
import SwiftUI

extension AnimationValues {
  /// 侧栏开合、Space 分页、行排序、悬停与清空反馈。分页保留期随动画一起缩放。
  enum Sidebar {
    @MainActor static var collapseDuration: TimeInterval { AnimationValues.duration(0.28) }
    @MainActor static var pagingDuration: TimeInterval { AnimationValues.duration(0.34) }
    @MainActor static var pageRetentionDuration: TimeInterval { AnimationValues.duration(0.4) }
    @MainActor static var reorderDuration: TimeInterval { AnimationValues.duration(0.28) }
    @MainActor static var spacePinToggleDuration: TimeInterval { AnimationValues.duration(0.36) }
    @MainActor static var spacePinToggleAnimation: Animation { .easeInOut(duration: spacePinToggleDuration) }
    static let spacePinFadeStart: CGFloat = 0.55
    static func spacePinOpacity(hiddenProgress: CGFloat) -> Double {
      let fade = min(1, max(0, (hiddenProgress - spacePinFadeStart) / (1 - spacePinFadeStart)))
      return Double(1 - fade * fade * (3 - 2 * fade))
    }
    static let spacePinExpandedDisclosureAngle: Double = 90
    @MainActor static var clearHoverDuration: TimeInterval { AnimationValues.duration(0.18) }
    @MainActor static var clearTiltDuration: TimeInterval { AnimationValues.duration(0.14) }
    @MainActor static var clearReturnDuration: TimeInterval { AnimationValues.duration(0.16) }
    @MainActor static var hoverDuration: TimeInterval { AnimationValues.duration(0.16) }
    // Match the address reload icon while keeping the close hit area fixed.
    @MainActor static var closeButtonHoverDuration: TimeInterval { AnimationValues.AddressField.hoverDuration }
    static let closeButtonHoverScale = AnimationValues.AddressField.hoverScale
    static let clearTiltAngle: Double = 18
    static let clearLidAngle: Double = -18
    static let selectedTopPinScale: CGFloat = 1.02
  }
}
