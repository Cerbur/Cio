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
                   drop: DropPosition? = nil) -> [Self] {
    func tabRows(_ ids: [UUID], tier: WorkspaceCollection.TabTier) -> [Self] {
      let available = ids.filter { id in
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
      if liftedID != nil, let drop, drop.tier == tier {
        let index = drop.before.flatMap { before in rows.firstIndex { $0.tabIDs.contains(before) } }
        rows.insert(Self(id: .gap(spaceID), elements: [], tier: tier), at: index ?? rows.count)
      }
      return rows
    }

    let pins = tabRows(pinnedIDs, tier: .space(spaceID))
    let temporary = tabRows(temporaryIDs, tier: .temporary(spaceID))
    return pins + [
      Self(id: .divider(spaceID), elements: [.divider], tier: nil),
      Self(id: .newTab(spaceID), elements: [.newTab], tier: nil),
    ] + temporary + [
      Self(id: .footer(spaceID), elements: [], tier: .temporary(spaceID)),
    ]
  }
}
