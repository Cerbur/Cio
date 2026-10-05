import Foundation

/// A durable two- or three-tab group. Runtime views and Chromium sessions are separate.
struct BrowserSplitLayout: Identifiable, Codable, Equatable, Sendable {
  enum Side { case left, middle, right }
  var id: UUID = UUID()
  var leftTabID: UUID
  var rightTabID: UUID
  var fraction: CGFloat = 0.5
  var focusedTabID: UUID? = nil
  var middleTabID: UUID? = nil
  /// Second divider position as a fraction of usable width (three panes only).
  var secondFraction: CGFloat? = nil

  var tabIDs: [UUID] { [leftTabID] + (middleTabID.map { [$0] } ?? []) + [rightTabID] }
  func contains(_ id: UUID?) -> Bool { id.map { tabIDs.contains($0) } ?? false }

  static let dividerWidth: CGFloat = 8
  static let minimumPaneWidth: CGFloat = 240

  static func clampedFraction(_ fraction: CGFloat, width: CGFloat) -> CGFloat {
    let usable = max(1, width - dividerWidth)
    let minimum = min(0.5, minimumPaneWidth / usable)
    return min(max(fraction, minimum), 1 - minimum)
  }

  /// Drop zones stay equal thirds, independent of committed divider widths.
  static func dropSide(at x: CGFloat, in bounds: CGRect) -> Side {
    let fraction = (x - bounds.minX) / max(1, bounds.width)
    return fraction < 1.0 / 3 ? .left : (fraction < 2.0 / 3 ? .middle : .right)
  }

  func clampedFractions(width: CGFloat) -> (first: CGFloat, second: CGFloat) {
    let usable = max(1, width - 2 * Self.dividerWidth)
    let minimum = min(1.0 / 3, Self.minimumPaneWidth / usable)
    let first = min(max(fraction, minimum), 1 - 2 * minimum)
    let second = min(max(secondFraction ?? 2.0 / 3, first + minimum), 1 - minimum)
    return (first, second)
  }

  func paneFrames(in bounds: CGRect) -> (panes: [CGRect], dividers: [CGRect]) {
    guard middleTabID != nil else {
      let frames = frames(in: bounds)
      return ([frames.left, frames.right], [frames.divider])
    }
    let gap = min(Self.dividerWidth, max(0, bounds.width / 2))
    let usable = max(0, bounds.width - 2 * gap)
    let fractions = clampedFractions(width: bounds.width)
    let edges: [CGFloat] = [0, (usable * fractions.first).rounded(),
                           (usable * fractions.second).rounded(), usable]
    let panes = (0..<3).map { index in
      CGRect(x: bounds.minX + edges[index] + CGFloat(index) * gap, y: bounds.minY,
             width: max(0, edges[index + 1] - edges[index]), height: bounds.height)
    }
    let dividers = (0..<2).map { index in
      CGRect(x: panes[index].maxX, y: bounds.minY, width: gap, height: bounds.height)
    }
    return (panes, dividers)
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
