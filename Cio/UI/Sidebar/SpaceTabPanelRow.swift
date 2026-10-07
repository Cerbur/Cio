import Foundation

/// One ordered container in a Space panel. Tier is membership, not identity:
/// moving a tab across the divider keeps the same row and its element state.
struct SpaceTabPanelRow: Identifiable, Equatable {
  enum ID: Hashable {
    case tab(UUID), group(UUID), divider(UUID), newTab(UUID)
    case gap(UUID), footer(UUID)
  }

  enum Element: Equatable {
    case tab(UUID)
    case divider
    case newTab
  }

  struct DropPosition {
    let tier: WorkspaceCollection.TabTier
    let before: UUID?
  }

  /// A visual reservation outlives the midpoint's durable split edit. The
  /// destination uses its final tab identity from the moment the flight starts.
  struct PaneCollapse: Equatable {
    let tabID: UUID
    let tier: WorkspaceCollection.TabTier
    let group: BrowserSplitLayout
  }

  let id: ID
  let elements: [Element]
  let tier: WorkspaceCollection.TabTier?
  var splitGroup: BrowserSplitLayout?

  var tabIDs: [UUID] {
    elements.compactMap { if case .tab(let id) = $0 { id } else { nil } }
  }

  var draggableTabID: UUID? { tabIDs.first }

  static func make(spaceID: UUID, pinnedIDs: [UUID], temporaryIDs: [UUID],
                   groups: [BrowserSplitLayout], liftedID: UUID? = nil,
                   liftedIDs: Set<UUID>? = nil, drop: DropPosition? = nil,
                   paneCollapse: PaneCollapse? = nil) -> [Self] {
    let pins = makeTabs(pinnedIDs, spaceID: spaceID, tier: .space(spaceID), groups: groups,
      liftedID: liftedID, liftedIDs: liftedIDs, drop: drop, paneCollapse: paneCollapse)
    let temporary = makeTabs(temporaryIDs, spaceID: spaceID, tier: .temporary(spaceID), groups: groups,
      liftedID: liftedID, liftedIDs: liftedIDs, drop: drop, paneCollapse: paneCollapse)
    return pins + [
      Self(id: .divider(spaceID), elements: [.divider], tier: nil),
      Self(id: .newTab(spaceID), elements: [.newTab], tier: nil),
    ] + temporary + [
      Self(id: .footer(spaceID), elements: [], tier: .temporary(spaceID)),
    ]
  }

  /// Shared by Space rows and the Top Pin grid so both reserve the same final
  /// order without mutating workspace membership ahead of the page midpoint.
  static func makeTabs(_ ids: [UUID], spaceID: UUID, tier: WorkspaceCollection.TabTier,
                       groups: [BrowserSplitLayout], liftedID: UUID? = nil,
                       liftedIDs: Set<UUID>? = nil, drop: DropPosition? = nil,
                       paneCollapse: PaneCollapse? = nil) -> [Self] {
    let available = ids.filter { id in
      // Hide only the captured source, not survivors of a newly committed group
      // that happens to contain that source during the drag/page handoff.
      if let liftedIDs { return !liftedIDs.contains(id) }
      guard let liftedID else { return true }
      return id != liftedID && !(groups.first { $0.contains(id) }?.contains(liftedID) ?? false)
    }
    let members = Set(available)
    var emitted = Set<UUID>()
    var rows: [Self] = []
    for id in available where !emitted.contains(id) {
      if let group = groups.first(where: { $0.contains(id) }), group.tabIDs.allSatisfy(members.contains) {
        rows.append(Self(id: .group(group.id), elements: group.tabIDs.map(Element.tab),
                         tier: tier, splitGroup: group))
        emitted.formUnion(group.tabIDs)
      } else {
        rows.append(Self(id: .tab(id), elements: [.tab(id)], tier: tier))
        emitted.insert(id)
      }
    }
    if let collapse = paneCollapse, collapse.tier == tier,
       collapse.group.tabIDs.allSatisfy(members.contains),
       let index = rows.firstIndex(where: { $0.tabIDs.contains { collapse.group.contains($0) } }) {
      // Keep the source container anchored even when a two-pane group becomes
      // a single tab. Its contents follow the committed group at the midpoint.
      let remaining = collapse.group.tabIDs.filter { $0 != collapse.tabID }
      let survivor = Self(id: .group(collapse.group.id), elements: remaining.map(Element.tab),
        tier: tier, splitGroup: groups.first { $0.id == collapse.group.id })
      let destination = Self(id: .tab(collapse.tabID), elements: [.tab(collapse.tabID)], tier: tier)
      rows.removeAll { $0.tabIDs.contains { collapse.group.contains($0) } }
      rows.insert(contentsOf: [survivor, destination], at: index)
    }
    // An incoming pane has no lifted sidebar row: its split group stays in
    // place. The virtual destination still reserves a full row in the list.
    if let drop, drop.tier == tier {
      let index = drop.before.flatMap { before in rows.firstIndex { $0.tabIDs.contains(before) } }
      rows.insert(Self(id: .gap(spaceID), elements: [], tier: tier), at: index ?? rows.count)
    }
    return rows
  }
}
