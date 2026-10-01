import Foundation

/// Window-local split presentation. The tabs and Chromium sessions keep their identities.
struct BrowserSplitLayout: Equatable {
  enum Side { case left, right }
  var leftTabID: UUID
  var rightTabID: UUID
  var fraction: CGFloat = 0.5

  var tabIDs: [UUID] { [leftTabID, rightTabID] }
  func contains(_ id: UUID?) -> Bool { id == leftTabID || id == rightTabID }

  static let dividerWidth: CGFloat = 8
  static let minimumPaneWidth: CGFloat = 240

  static func clampedFraction(_ fraction: CGFloat, width: CGFloat) -> CGFloat {
    let usable = max(1, width - dividerWidth)
    let minimum = min(0.5, minimumPaneWidth / usable)
    return min(max(fraction, minimum), 1 - minimum)
  }

  /// The existing page and its toolbar share the same cropped preview frame.
  static func previewFrames(in bounds: CGRect, on side: Side,
                            maximumSurvivorWidth: CGFloat = .greatestFiniteMagnitude
  ) -> (target: CGRect, survivor: CGRect) {
    let usable = max(0, bounds.width - dividerWidth)
    // A previously narrow pane cannot expand during a crop-only preview.
    let survivorWidth = min(usable / 2, max(0, maximumSurvivorWidth))
    let targetWidth = usable - survivorWidth
    if side == .left {
      return (
        CGRect(x: bounds.minX, y: bounds.minY, width: targetWidth, height: bounds.height),
        CGRect(x: bounds.maxX - survivorWidth, y: bounds.minY, width: survivorWidth, height: bounds.height))
    }
    return (
      CGRect(x: bounds.maxX - targetWidth, y: bounds.minY, width: targetWidth, height: bounds.height),
      CGRect(x: bounds.minX, y: bounds.minY, width: survivorWidth, height: bounds.height))
  }

  func frames(in bounds: CGRect, toolbarHeight: CGFloat = 0) -> (left: CGRect, divider: CGRect, right: CGRect) {
    let usable = max(0, bounds.width - Self.dividerWidth)
    let leftWidth = (usable * Self.clampedFraction(fraction, width: bounds.width)).rounded()
    let height = max(0, bounds.height - toolbarHeight)
    return (
      CGRect(x: bounds.minX, y: bounds.minY + toolbarHeight, width: leftWidth, height: height),
      CGRect(x: bounds.minX + leftWidth, y: bounds.minY, width: Self.dividerWidth, height: bounds.height),
      CGRect(x: bounds.minX + leftWidth + Self.dividerWidth, y: bounds.minY + toolbarHeight,
             width: max(0, usable - leftWidth), height: height))
  }
}
