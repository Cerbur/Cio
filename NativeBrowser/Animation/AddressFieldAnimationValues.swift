import Foundation

extension AnimationValues {
  /// 地址胶囊展开、站点信息面板、焦点环和尾部按钮反馈。
  enum AddressField {
    @MainActor static var focusRingDuration: TimeInterval { AnimationValues.duration(0.18) }
    @MainActor static var expansionResponse: TimeInterval { AnimationValues.duration(0.31) }
    @MainActor static var siteInformationResponse: TimeInterval { AnimationValues.duration(0.36) }
    @MainActor static var buttonFocusDuration: TimeInterval { AnimationValues.duration(0.18) }
    @MainActor static var hoverDuration: TimeInterval { AnimationValues.duration(0.15) }
    @MainActor static var informationPageDuration: TimeInterval { AnimationValues.duration(0.18) }
    /// 加载标记每转一圈的时间；TimelineView 也必须使用统一速度。
    @MainActor static var reloadRotationDuration: TimeInterval { AnimationValues.duration(0.9) }
    static let expansionDamping = 0.68
    static let siteInformationDamping = 0.82
    static let hoverScale: CGFloat = 16.0 / 14.0
    static let compactTextOffset: CGFloat = -12
  }
}
