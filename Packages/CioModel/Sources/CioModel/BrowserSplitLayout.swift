import CoreGraphics
import Foundation

/// A durable two- or three-tab group. Runtime views and Chromium sessions are separate.
public struct BrowserSplitLayout: Identifiable, Codable, Equatable, Sendable {
  public enum Side: Sendable { case left, middle, right }
  public struct DropTarget: Equatable, Sendable {
    public var side: Side
    public var replacesPane = false

    public init(side: Side, replacesPane: Bool = false) {
      self.side = side
      self.replacesPane = replacesPane
    }
  }
  public var id: UUID = UUID()
  public var leftTabID: UUID
  public var rightTabID: UUID
  public var fraction: CGFloat = 0.5
  public var focusedTabID: UUID? = nil
  public var middleTabID: UUID? = nil
  /// Second divider position as a fraction of usable width (three panes only).
  public var secondFraction: CGFloat? = nil

  public var tabIDs: [UUID] { [leftTabID] + (middleTabID.map { [$0] } ?? []) + [rightTabID] }
  public func contains(_ id: UUID?) -> Bool { id.map { tabIDs.contains($0) } ?? false }

  /// Reorder one pane without displacing or duplicating any other member.
  public func movingPane(_ tabID: UUID, to index: Int) -> BrowserSplitLayout {
    guard contains(tabID) else { return self }
    var ids = tabIDs.filter { $0 != tabID }
    ids.insert(tabID, at: min(max(0, index), ids.count))
    var result = self
    result.leftTabID = ids[0]
    result.rightTabID = ids.last!
    result.middleTabID = ids.count == 3 ? ids[1] : nil
    return result
  }

  /// Edge/divider drops insert; pane-body drops replace. A full group replaces.
  /// Previews and committed groups use the same ordering and divider positions.
  public func placingPane(_ tabID: UUID, on side: Side) -> BrowserSplitLayout {
    placingPane(tabID, at: DropTarget(side: side))
  }

  public func placingPane(_ tabID: UUID, at target: DropTarget) -> BrowserSplitLayout {
    var ids = tabIDs
    let side = target.side
    let index = side == .left ? 0 : (side == .middle ? 1 : ids.count)
    if ids.count == 3 || target.replacesPane {
      ids[side == .right ? ids.count - 1 : index] = tabID
    } else {
      ids.insert(tabID, at: index)
    }
    var result = self
    result.leftTabID = ids[0]
    result.middleTabID = ids.count == 3 ? ids[1] : nil
    result.rightTabID = ids.last!
    result.focusedTabID = tabID
    if ids.count == 3, middleTabID == nil {
      result.fraction = 1.0 / 3
      result.secondFraction = 2.0 / 3
    }
    return result
  }

  public static let dividerWidth: CGFloat = 8
  public static let minimumPaneWidth: CGFloat = 240

  public static func clampedFraction(_ fraction: CGFloat, width: CGFloat) -> CGFloat {
    let usable = max(1, width - dividerWidth)
    let minimum = min(0.5, minimumPaneWidth / usable)
    return min(max(fraction, minimum), 1 - minimum)
  }

  public static let dropBoundarySlop: CGFloat = 8

  /// Enter through the outer thirds; keep an open slot until the pointer
  /// leaves its final preview frame. Trigger geometry never follows animation.
  public static func dropSide(at x: CGFloat, in bounds: CGRect, previous: Side? = nil,
                       incomingPaneCount: Int = 1) -> Side {
    if let previous, previous != .middle {
      let width = max(0, bounds.width - CGFloat(incomingPaneCount) * dividerWidth)
      let slotWidth = width * CGFloat(incomingPaneCount) / CGFloat(incomingPaneCount + 1)
        + CGFloat(incomingPaneCount - 1) * dividerWidth
      let start = previous == .left ? bounds.minX : bounds.maxX - slotWidth
      if x >= start - dropBoundarySlop && x <= start + slotWidth + dropBoundarySlop {
        return previous
      }
    }
    let fraction = (x - bounds.minX) / max(1, bounds.width)
    return fraction < 1.0 / 3 ? .left : (fraction < 2.0 / 3 ? .middle : .right)
  }

  /// Resolve against committed geometry, so moving a preview cannot move its
  /// own trigger zone. The middle insertion zone straddles the existing divider.
  public func dropTarget(at x: CGFloat, in bounds: CGRect, previous: DropTarget? = nil) -> DropTarget {
    let frames = paneFrames(in: bounds)
    if middleTabID == nil {
      if let previous, !previous.replacesPane {
        let placeholder = UUID()
        let shown = placingPane(placeholder, at: previous)
        let index = shown.tabIDs.firstIndex(of: placeholder)!
        let slot = shown.paneFrames(in: bounds).panes[index]
        if x >= slot.minX - Self.dropBoundarySlop && x <= slot.maxX + Self.dropBoundarySlop {
          return previous
        }
      }
      // Reserve narrow strips for insertion, leaving each pane's body available
      // for replacement. Size outer strips from their own pane so a narrow
      // neighbour cannot make the wider pane's edge difficult to acquire.
      func insertionWidth(_ width: CGFloat) -> CGFloat {
        min(width / 4, min(96, max(44, width / 5)))
      }
      let leftWidth = insertionWidth(frames.panes[0].width)
      let rightWidth = insertionWidth(frames.panes[1].width)
      let dividerZoneWidth = min(leftWidth, rightWidth)
      if x < bounds.minX + leftWidth { return DropTarget(side: .left) }
      if x >= bounds.maxX - rightWidth { return DropTarget(side: .right) }
      if abs(x - frames.dividers[0].midX) <= dividerZoneWidth {
        return DropTarget(side: .middle)
      }
    }
    if middleTabID != nil, let previous, previous.replacesPane {
      let index = previous.side == .left ? 0 : (previous.side == .middle ? 1 : 2)
      let pane = frames.panes[index]
      if x >= pane.minX - Self.dropBoundarySlop && x <= pane.maxX + Self.dropBoundarySlop {
        return previous
      }
    }
    let index = dropPaneIndex(at: x, in: bounds)
    let side: Side = index == 0 ? .left : (middleTabID == nil || index == 2 ? .right : .middle)
    return DropTarget(side: side, replacesPane: true)
  }

  /// Reordering targets the pane under the pointer, including resized panes.
  public func dropPaneIndex(at x: CGFloat, in bounds: CGRect, previous: Int? = nil) -> Int {
    let dividers = paneFrames(in: bounds).dividers
    if let previous, (0...dividers.count).contains(previous) {
      // Keep the current slot across small pointer movements at a divider.
      // These boundaries belong to the committed layout, never its animation.
      let lower = previous == 0 ? -CGFloat.infinity : dividers[previous - 1].midX - Self.dropBoundarySlop
      let upper = previous == dividers.count ? CGFloat.infinity : dividers[previous].midX + Self.dropBoundarySlop
      if x >= lower && x <= upper { return previous }
    }
    return dividers.firstIndex(where: { x < $0.midX }) ?? dividers.count
  }

  public func clampedFractions(width: CGFloat) -> (first: CGFloat, second: CGFloat) {
    let usable = max(1, width - 2 * Self.dividerWidth)
    let minimum = min(1.0 / 3, Self.minimumPaneWidth / usable)
    let first = min(max(fraction, minimum), 1 - 2 * minimum)
    let second = min(max(secondFraction ?? 2.0 / 3, first + minimum), 1 - minimum)
    return (first, second)
  }

  public func paneFrames(in bounds: CGRect) -> (panes: [CGRect], dividers: [CGRect]) {
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
  public static func previewFrames(in bounds: CGRect, on side: Side,
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

  public func frames(in bounds: CGRect, toolbarHeight: CGFloat = 0) -> (left: CGRect, divider: CGRect, right: CGRect) {
    let usable = max(0, bounds.width - Self.dividerWidth)
    let leftWidth = (usable * Self.clampedFraction(fraction, width: bounds.width)).rounded()
    let height = max(0, bounds.height - toolbarHeight)
    return (
      CGRect(x: bounds.minX, y: bounds.minY + toolbarHeight, width: leftWidth, height: height),
      CGRect(x: bounds.minX + leftWidth, y: bounds.minY, width: Self.dividerWidth, height: bounds.height),
      CGRect(x: bounds.minX + leftWidth + Self.dividerWidth, y: bounds.minY + toolbarHeight,
             width: max(0, usable - leftWidth), height: height))
  }

  public init(
    id: UUID = UUID(),
    leftTabID: UUID,
    rightTabID: UUID,
    fraction: CGFloat = 0.5,
    focusedTabID: UUID? = nil,
    middleTabID: UUID? = nil,
    secondFraction: CGFloat? = nil
  ) {
    self.id = id
    self.leftTabID = leftTabID
    self.rightTabID = rightTabID
    self.fraction = fraction
    self.focusedTabID = focusedTabID
    self.middleTabID = middleTabID
    self.secondFraction = secondFraction
  }
}
