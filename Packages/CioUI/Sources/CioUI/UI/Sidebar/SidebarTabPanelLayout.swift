import Foundation

/// Visible tabs live in one flat collection, outside the structural row views.
/// Joining, leaving or reordering a split changes geometry, never control identity.
struct SidebarTabPanelItem: Identifiable, Equatable {
  enum ID: Hashable {
    case row(SpaceTabPanelRow.ID)
    case tab(UUID)
  }

  let row: SpaceTabPanelRow
  let tabID: UUID?

  var id: ID { tabID.map(ID.tab) ?? .row(row.id) }

  static func make(_ rows: [SpaceTabPanelRow]) -> [Self] {
    let decorations = rows.map { Self(row: $0, tabID: nil) }
    let members = rows.flatMap { row in row.tabIDs.map { Self(row: row, tabID: $0) } }
    return decorations + members.sorted { $0.tabID!.uuidString < $1.tabID!.uuidString }
  }
}

struct SidebarTabPanelLayout {
  /// Compare logical slots, never animated frames. Every drag source and
  /// ordinary reorder reaches this same container-owned feedback decision.
  struct FeedbackSnapshot: Equatable {
    struct Slot: Equatable {
      let row: Int
      let column: Int
      let member: Int
      let memberCount: Int
    }
    let slots: [UUID: Slot]
    let hasGap: Bool

    func feedback(from previous: Self) -> BrowserDragHaptics.Feedback? {
      // Removing a reservation restores space; its commit already received
      // feedback when the neighbours first made room for the destination.
      guard !(previous.hasGap && !hasGap) else { return nil }
      let ids = Set(slots.keys), previousIDs = Set(previous.slots.keys)
      // Source lift/closure alone removes space, rather than compressing it.
      guard hasGap || !ids.isStrictSubset(of: previousIDs) else { return nil }
      return slots.contains { id, slot in
        previous.slots[id].map { $0 != slot } ?? false
      } ? .compression : nil
    }
  }

  struct RowDestination: Equatable {
    let id: SpaceTabPanelRow.ID
    let members: [UUID]
  }

  let rows: [SpaceTabPanelRow]
  var columns = 1
  var rowHeight = BrowserLayout.sidebarTabRowHeight
  var rowSpacing = BrowserLayout.sidebarRowSpacing
  var columnSpacing = BrowserLayout.sidebarTopPinSpacing

  var destinations: [RowDestination] {
    rows.map { RowDestination(id: $0.id, members: $0.tabIDs) }
  }

  var feedbackSnapshot: FeedbackSnapshot {
    var slots: [UUID: FeedbackSnapshot.Slot] = [:]
    let columns = max(1, columns)
    for (index, row) in rows.enumerated() {
      for (member, id) in row.tabIDs.enumerated() {
        slots[id] = .init(row: index / columns, column: index % columns,
                         member: member, memberCount: row.tabIDs.count)
      }
    }
    return FeedbackSnapshot(slots: slots, hasGap: rows.contains {
      if case .gap = $0.id { return true }; return false
    })
  }

  var height: CGFloat {
    let count = (rows.count + max(1, columns) - 1) / max(1, columns)
    return CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowSpacing
  }

  func frames(width: CGFloat) -> [SidebarTabPanelItem.ID: CGRect] {
    let columns = max(1, columns)
    let width = max(0, width - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns)
    var frames: [SidebarTabPanelItem.ID: CGRect] = [:]
    for (index, row) in rows.enumerated() {
      let origin = CGPoint(x: CGFloat(index % columns) * (width + columnSpacing),
        y: CGFloat(index / columns) * (rowHeight + rowSpacing))
      frames[.row(row.id)] = CGRect(origin: origin, size: CGSize(width: width, height: rowHeight))
      let count = row.tabIDs.count
      guard count > 0 else { continue }
      let gap = BrowserLayout.sidebarSplitMemberSpacing
      let memberWidth = max(0, width - CGFloat(count - 1) * gap) / CGFloat(count)
      for (memberIndex, id) in row.tabIDs.enumerated() {
        frames[.tab(id)] = CGRect(x: origin.x + CGFloat(memberIndex) * (memberWidth + gap),
          y: origin.y, width: memberWidth, height: rowHeight)
      }
    }
    return frames
  }
}
