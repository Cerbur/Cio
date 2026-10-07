//
//  WorkspaceCollection.swift
//  Cio
//
//  Pure workspace/domain state for Milestone 4. This file has no AppKit or CEF
//  dependency and is the only source of truth for Spaces, tab membership,
//  ordering, selection and recently-closed policy.
//

import Foundation

/// Why a tab is being removed from the workspace.
public enum WorkspaceTabCloseReason: Equatable, Sendable {
  case userClosed
  case applicationTerminating
}

/// What happened to a tab's selection when it was removed.
public enum WorkspaceTabRemovalOutcome: Equatable, Sendable {
  case unknownTab
  case removedSelectionUnchanged
  case removedSelectionMoved(to: UUID)
  case removedLast
}

/// The result the runtime owner needs after a domain close.
public struct WorkspaceTabCloseResult: Equatable, Sendable {
  public var outcome: WorkspaceTabRemovalOutcome
  public var spaceID: UUID?
  public var snapshot: ClosedTabSnapshot?
  public var needsReplacementTab: Bool
}

/// All in-memory workspace relationships.
///
/// The collection owns one tab dictionary and one ordered list per Space. The
/// dictionary is an identity index only; every ordered traversal goes through a
/// Space's `tabIDs`, so Space and tab order are deterministic.
public struct WorkspaceCollection: Equatable, Sendable {
  public static let recentlyClosedLimit = 10
  public static let globalPinnedTabLimit = 16

  public private(set) var spaces: [BrowserSpace]
  public private(set) var selectedSpaceID: UUID
  public private(set) var tabsByID: [UUID: BrowserTab]
  public private(set) var recentlyClosed: [ClosedTabSnapshot]
  public private(set) var globalPinnedTabIDs: [UUID]
  public private(set) var selectedGlobalTabID: UUID?

  /// Creates the normal application starting state: one Main Space, one tab,
  /// and both levels of selection pointing at that tab.
  public init(initialTab: BrowserTab, spaceName: String = "Main") {
    let space = BrowserSpace(
      name: Self.normalizedInitialSpaceName(spaceName),
      tabIDs: [initialTab.id],
      selectedTabID: initialTab.id,
      stableTabStack: [initialTab.id])
    self.spaces = [space]
    self.selectedSpaceID = space.id
    self.tabsByID = [initialTab.id: initialTab]
    self.recentlyClosed = []
    self.globalPinnedTabIDs = []
    self.selectedGlobalTabID = nil
    validateInvariants()
  }

  /// Reconstructs the pure domain graph from a validated durable snapshot.
  ///
  /// Validation happens before any state is assigned to `self`, so callers get
  /// an all-or-fresh restore decision rather than a partially repaired graph.
  /// Runtime-only fields are intentionally reset: a relaunch starts with no
  /// loading state, CEF history or recently-closed stack.
  public init(restoring snapshot: WorkspaceSessionSnapshot) throws {
    guard snapshot.schemaVersion == WorkspaceSessionSnapshot.currentSchemaVersion else {
      throw WorkspaceSessionSnapshotError.unsupportedSchema
    }
    guard !snapshot.spaces.isEmpty else {
      throw WorkspaceSessionSnapshotError.noSpaces
    }

    var restoredSpaces: [BrowserSpace] = []
    var restoredTabs: [UUID: BrowserTab] = [:]
    var spaceIDs = Set<UUID>()
    var tabIDs = Set<UUID>()

    for persistedSpace in snapshot.spaces {
      guard spaceIDs.insert(persistedSpace.id).inserted else {
        throw WorkspaceSessionSnapshotError.duplicateSpaceID
      }

      let name = persistedSpace.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw WorkspaceSessionSnapshotError.emptySpaceName
      }
      guard !persistedSpace.tabs.isEmpty else {
        throw WorkspaceSessionSnapshotError.emptySpace
      }
      guard let selectedTabID = persistedSpace.selectedTabID else {
        throw WorkspaceSessionSnapshotError.missingSelectedTab
      }

      var orderedTabIDs: [UUID] = []
      orderedTabIDs.reserveCapacity(persistedSpace.tabs.count)
      for persistedTab in persistedSpace.tabs {
        guard tabIDs.insert(persistedTab.id).inserted else {
          throw WorkspaceSessionSnapshotError.duplicateTabID
        }

        let url: URL?
        if let rawURL = persistedTab.url {
          guard !rawURL.isEmpty, let decodedURL = URL(string: rawURL), decodedURL.scheme != nil else {
            throw WorkspaceSessionSnapshotError.invalidURL
          }
          url = decodedURL
        } else {
          url = nil
        }

        orderedTabIDs.append(persistedTab.id)
        restoredTabs[persistedTab.id] = BrowserTab(
          id: persistedTab.id,
          title: persistedTab.title,
          url: url,
          isLoading: false,
          createdAt: persistedTab.createdAt,
          lastActivatedAt: persistedTab.lastActivatedAt)
      }

      guard orderedTabIDs.contains(selectedTabID) else {
        throw WorkspaceSessionSnapshotError.selectedTabNotInSpace
      }
      guard Set(persistedSpace.pinnedTabIDs).count == persistedSpace.pinnedTabIDs.count,
        persistedSpace.pinnedTabIDs.allSatisfy({ orderedTabIDs.contains($0) })
      else { throw WorkspaceSessionSnapshotError.invalidPinnedTabs }
      restoredSpaces.append(
        BrowserSpace(
          id: persistedSpace.id,
          name: name,
          icon: persistedSpace.icon,
          tabIDs: orderedTabIDs,
          pinnedTabIDs: persistedSpace.pinnedTabIDs,
          selectedTabID: selectedTabID,
          stableTabStack: persistedSpace.stableTabStack,
          splitGroups: persistedSpace.splitGroups))
    }

    guard spaceIDs.contains(snapshot.selectedSpaceID) else {
      throw WorkspaceSessionSnapshotError.missingSelectedSpace
    }

    self.spaces = restoredSpaces
    self.selectedSpaceID = snapshot.selectedSpaceID
    self.tabsByID = restoredTabs
    self.recentlyClosed = []
    self.globalPinnedTabIDs = snapshot.globalPinnedTabIDs
    self.selectedGlobalTabID = snapshot.selectedGlobalTabID

    // The stack is a soft link into the tab graph. Missing or moved IDs can
    // remain after background operations; duplicate entries are corrupt.
    for index in spaces.indices {
      let stack = spaces[index].stableTabStack
      if Set(stack).count != stack.count {
        spaces[index].stableTabStack = []
      }
    }

    guard globalPinnedTabIDs.count <= Self.globalPinnedTabLimit,
      Set(globalPinnedTabIDs).count == globalPinnedTabIDs.count,
      globalPinnedTabIDs.allSatisfy({ restoredTabs[$0] != nil }),
      selectedGlobalTabID.map({ globalPinnedTabIDs.contains($0) }) ?? true,
      restoredSpaces.allSatisfy({ Set($0.pinnedTabIDs).isDisjoint(with: globalPinnedTabIDs) })
    else { throw WorkspaceSessionSnapshotError.invalidPinnedTabs }

    // Layout records are soft links. Repair bad or overlapping groups without
    // losing the valid tab graph, including snapshots written before groups.
    var seenGroupIDs = Set<UUID>()
    for index in spaces.indices {
      var groupedTabs = Set<UUID>()
      let space = spaces[index]
      spaces[index].splitGroups = space.splitGroups.filter { group in
        guard Self.validGroup(group, in: space, globals: globalPinnedTabIDs),
              !seenGroupIDs.contains(group.id), groupedTabs.isDisjoint(with: group.tabIDs) else { return false }
        seenGroupIDs.insert(group.id)
        groupedTabs.formUnion(group.tabIDs)
        return true
      }
    }

    guard validateInvariants() else {
      // The explicit checks above cover the serialized graph. Keep this final
      // assertion as a defense against future model changes that add another
      // invariant without updating the restore path.
      throw WorkspaceSessionSnapshotError.selectedTabNotInSpace
    }
  }

  // MARK: - Derived selection and ordering

  public var selectedSpace: BrowserSpace? {
    spaces.first { $0.id == selectedSpaceID }
  }

  /// The one authoritative effective selected tab for the whole application.
  public var selectedTabID: UUID? {
    selectedGlobalTabID ?? selectedSpace?.selectedTabID
  }

  public var selectedTab: BrowserTab? {
    selectedTabID.flatMap { tabsByID[$0] }
  }

  public var spaceIDs: [UUID] { spaces.map(\.id) }

  /// All visible tabs in deterministic Space order, then per-Space tab order.
  public var allTabs: [BrowserTab] {
    spaces.flatMap { tabs(in: $0.id) }
  }

  public var allTabIDs: [UUID] {
    spaces.flatMap(\.tabIDs)
  }

  public var currentTabs: [BrowserTab] {
    tabs(in: selectedSpaceID)
  }

  public var globalPinnedTabs: [BrowserTab] {
    globalPinnedTabIDs.compactMap { tabsByID[$0] }
  }

  public var currentSpacePinnedTabs: [BrowserTab] {
    guard let space = selectedSpace else { return [] }
    return space.pinnedTabIDs.compactMap { tabsByID[$0] }
  }

  public var currentTemporaryTabs: [BrowserTab] {
    guard let space = selectedSpace else { return [] }
    return space.tabIDs.filter { !space.pinnedTabIDs.contains($0) && !globalPinnedTabIDs.contains($0) }
      .compactMap { tabsByID[$0] }
  }

  public var currentTabIDs: [UUID] {
    selectedSpace?.tabIDs ?? []
  }

  public var activeSplit: BrowserSplitLayout? {
    selectedTabID.flatMap { splitGroup(containing: $0) }
  }

  public func splitGroup(containing tabID: UUID) -> BrowserSplitLayout? {
    guard let spaceID = spaceID(containing: tabID) else { return nil }
    return space(withID: spaceID)?.splitGroups.first { $0.contains(tabID) }
  }

  public func canSplit(with tabID: UUID) -> Bool {
    guard let selectedTabID, selectedTabID != tabID,
          tabsByID[tabID] != nil,
          globalPinnedTabIDs.contains(tabID) || selectedSpace?.tabIDs.contains(tabID) == true,
          activeSplit?.contains(tabID) != true else { return false }
    // A two-page incoming row can join a single page. Larger combinations
    // have no placement in the three-pane layout.
    let incomingCount = splitGroup(containing: tabID)?.tabIDs.count ?? 1
    return incomingCount == 1 || (activeSplit == nil && incomingCount == 2)
  }

  @discardableResult
  public mutating func createSplit(with tabID: UUID, on side: BrowserSplitLayout.Side) -> Bool {
    createSplit(with: tabID, at: BrowserSplitLayout.DropTarget(side: side))
  }

  @discardableResult
  public mutating func createSplit(with tabID: UUID, at target: BrowserSplitLayout.DropTarget) -> Bool {
    guard canSplit(with: tabID), let selectedTabID,
          let spaceIndex = index(of: selectedSpaceID) else { return false }
    let prior = activeSplit
    let side = target.side
    // The middle of a single page is the return/selection zone, including
    // when the dragged row represents an existing group.
    if side == .middle, prior == nil { return selectTab(id: tabID) }

    let incomingGroup = splitGroup(containing: tabID)
    let pinnedIDs = Set(globalPinnedTabIDs + spaces[spaceIndex].pinnedTabIDs)
    let originalIncoming = incomingGroup?.tabIDs ?? [tabID]
    let originalExisting = prior?.tabIDs ?? [selectedTabID]
    let existingIsPinned = pinnedIDs.contains(originalExisting[0])
    let incomingIsPinned = pinnedIDs.contains(originalIncoming[0])
    var displaced: [UUID] = []
    var retained = originalExisting
    if let prior {
      let placement = prior.placingPane(tabID, at: target)
      displaced = retained.filter { !placement.contains($0) }
      retained = retained.filter { placement.contains($0) }
    }
    let existingIDs = retained.map { existingIsPinned ? duplicateForSplit($0) : $0 }
    let incomingIDs = originalIncoming.map { incomingIsPinned ? duplicateForSplit($0) : $0 }
    let memberIDs: [UUID]
    switch side {
    case .left: memberIDs = incomingIDs + existingIDs
    case .middle: memberIDs = [existingIDs[0]] + incomingIDs + Array(existingIDs.dropFirst())
    case .right: memberIDs = existingIDs + incomingIDs
    }
    let focusedID = incomingIDs[originalIncoming.firstIndex(of: tabID) ?? 0]
    let isTriple = memberIDs.count == 3
    let groupID = !existingIsPinned && prior != nil ? prior!.id
      : (!incomingIsPinned ? incomingGroup?.id : nil) ?? UUID()
    let group = BrowserSplitLayout(id: groupID,
      leftTabID: memberIDs[0], rightTabID: memberIDs.last!,
      fraction: isTriple ? (prior?.middleTabID == nil ? 1.0 / 3 : prior!.fraction) : (prior?.fraction ?? 0.5),
      focusedTabID: focusedID, middleTabID: isTriple ? memberIDs[1] : nil,
      secondFraction: isTriple ? (prior?.secondFraction ?? 2.0 / 3) : nil)

    let removedIDs = Set((existingIsPinned ? [] : originalExisting)
      + (incomingIsPinned ? [] : originalIncoming) + memberIDs)
    let anchorID = existingIsPinned ? incomingIDs[0] : originalExisting[0]
    let space = spaces[spaceIndex]
    let anchorIndex = existingIsPinned && prior != nil ? newTabInsertionIndex(in: space.id)
      : (space.tabIDs.firstIndex(of: anchorID) ?? newTabInsertionIndex(in: space.id))
    let insertAt = space.tabIDs.prefix(anchorIndex).filter { !removedIDs.contains($0) }.count
    spaces[spaceIndex].splitGroups.removeAll {
      (!existingIsPinned && $0.id == prior?.id) || (!incomingIsPinned && $0.id == incomingGroup?.id)
    }
    spaces[spaceIndex].tabIDs.removeAll { removedIDs.contains($0) }
    spaces[spaceIndex].tabIDs.insert(contentsOf: memberIDs + (existingIsPinned ? [] : displaced), at: insertAt)
    spaces[spaceIndex].splitGroups.append(group)
    _ = selectTab(id: focusedID)
    validateInvariants()
    return true
  }

  private mutating func duplicateForSplit(_ tabID: UUID) -> UUID {
    let source = tabsByID[tabID]!
    let copy = BrowserTab(title: source.title, url: source.url)
    _ = insertTab(copy, in: selectedSpaceID,
      at: newTabInsertionIndex(in: selectedSpaceID), select: false)
    return copy.id
  }

  @discardableResult
  public mutating func setSplitFraction(_ fraction: CGFloat, divider: Int = 0) -> Bool {
    guard fraction.isFinite, let selectedTabID,
          let owner = spaceID(containing: selectedTabID), let spaceIndex = index(of: owner),
          let groupIndex = spaces[spaceIndex].splitGroups.firstIndex(where: { $0.contains(selectedTabID) }) else { return false }
    let value = min(max(fraction, 0.01), 0.99)
    if divider == 1, spaces[spaceIndex].splitGroups[groupIndex].middleTabID != nil {
      guard value > spaces[spaceIndex].splitGroups[groupIndex].fraction else { return false }
      spaces[spaceIndex].splitGroups[groupIndex].secondFraction = value
    } else {
      guard value < (spaces[spaceIndex].splitGroups[groupIndex].secondFraction ?? 1) else { return false }
      spaces[spaceIndex].splitGroups[groupIndex].fraction = value
    }
    return true
  }

  @discardableResult
  public mutating func endSplit(keeping tabID: UUID) -> Bool {
    guard let owner = spaceID(containing: tabID), let spaceIndex = index(of: owner),
          spaces[spaceIndex].splitGroups.contains(where: { $0.contains(tabID) }) else { return false }
    spaces[spaceIndex].splitGroups.removeAll { $0.contains(tabID) }
    return true
  }

  /// The sidebar's ungroup action makes the left pane the stable selection,
  /// even when the right pane (or another Space) was active before the click.
  @discardableResult
  public mutating func ungroupSplit(containing tabID: UUID) -> Bool {
    guard let group = splitGroup(containing: tabID),
          let owner = spaceID(containing: group.leftTabID) else { return false }
    _ = endSplit(keeping: group.leftTabID)
    if globalPinnedTabIDs.contains(group.leftTabID) {
      _ = selectTab(id: group.leftTabID)
    } else {
      _ = select(spaceID: owner, tabID: group.leftTabID)
    }
    return true
  }

  /// Extract just this page. Keep the remaining group at its sidebar position
  /// and insert the independent page immediately after that group in its tier.
  @discardableResult
  public mutating func detachSplitPane(_ tabID: UUID, selectDetached: Bool = false) -> Bool {
    guard let group = splitGroup(containing: tabID),
          let owner = spaceID(containing: tabID), let ownerIndex = index(of: owner),
          let groupIndex = spaces[ownerIndex].splitGroups.firstIndex(where: { $0.id == group.id }) else { return false }
    let remaining = group.tabIDs.filter { $0 != tabID }
    if remaining.count == 2 {
      spaces[ownerIndex].splitGroups[groupIndex] = BrowserSplitLayout(id: group.id,
        leftTabID: remaining[0], rightTabID: remaining[1], fraction: 0.5,
        focusedTabID: remaining.contains(group.focusedTabID ?? tabID) ? group.focusedTabID : remaining[0])
    } else {
      spaces[ownerIndex].splitGroups.remove(at: groupIndex)
    }
    rewriteSplitOrder(group.tabIDs, as: remaining + [tabID], in: ownerIndex)
    if selectDetached {
      _ = selectTab(id: tabID)
    } else if group.contains(selectedTabID) {
      _ = selectTab(id: selectedTabID == tabID ? (remaining.contains(group.focusedTabID ?? tabID)
        ? group.focusedTabID! : remaining[0]) : selectedTabID!)
    }
    validateInvariants()
    return true
  }

  /// A failed sidebar drop leaves membership and selection untouched.
  @discardableResult
  public mutating func moveSplitPane(_ tabID: UUID, to tier: TabTier, before targetID: UUID? = nil) -> Bool {
    guard let group = splitGroup(containing: tabID), !group.contains(targetID) else { return false }
    var candidate = self
    guard candidate.detachSplitPane(tabID), candidate.moveTab(tabID, to: tier, before: targetID) else { return false }
    self = candidate
    return true
  }

  @discardableResult
  public mutating func reorderSplitPane(_ tabID: UUID, to index: Int) -> Bool {
    guard let group = splitGroup(containing: tabID),
          let owner = spaceID(containing: tabID), let ownerIndex = self.index(of: owner),
          let groupIndex = spaces[ownerIndex].splitGroups.firstIndex(where: { $0.id == group.id }) else { return false }
    let reordered = group.movingPane(tabID, to: index)
    spaces[ownerIndex].splitGroups[groupIndex] = reordered
    rewriteSplitOrder(group.tabIDs, as: reordered.tabIDs, in: ownerIndex)
    validateInvariants()
    return true
  }

  private mutating func rewriteSplitOrder(_ old: [UUID], as new: [UUID], in spaceIndex: Int) {
    func rewritten(_ ids: [UUID]) -> [UUID] {
      guard let anchor = ids.firstIndex(where: { old.contains($0) }) else { return ids }
      let insertion = ids.prefix(anchor).filter { !old.contains($0) }.count
      var result = ids.filter { !old.contains($0) }
      result.insert(contentsOf: new, at: insertion)
      return result
    }
    spaces[spaceIndex].tabIDs = rewritten(spaces[spaceIndex].tabIDs)
    if globalPinnedTabIDs.contains(old[0]) { globalPinnedTabIDs = rewritten(globalPinnedTabIDs) }
    if spaces[spaceIndex].pinnedTabIDs.contains(old[0]) {
      spaces[spaceIndex].pinnedTabIDs = rewritten(spaces[spaceIndex].pinnedTabIDs)
    }
  }

  @discardableResult
  public mutating func swapSplitSides(containing tabID: UUID) -> Bool {
    guard let owner = spaceID(containing: tabID), let spaceIndex = index(of: owner),
          let groupIndex = spaces[spaceIndex].splitGroups.firstIndex(where: { $0.contains(tabID) }) else { return false }
    var group = spaces[spaceIndex].splitGroups[groupIndex]
    let left = group.leftTabID
    group.leftTabID = group.rightTabID
    group.rightTabID = left
    if group.middleTabID != nil {
      let first = group.fraction
      group.fraction = 1 - (group.secondFraction ?? 2.0 / 3)
      group.secondFraction = 1 - first
    } else {
      group.fraction = 1 - group.fraction
    }
    spaces[spaceIndex].splitGroups[groupIndex] = group
    return true
  }

  @discardableResult
  public mutating func moveSplitGroup(containing tabID: UUID, to tier: TabTier, before targetID: UUID? = nil) -> Bool {
    guard let group = splitGroup(containing: tabID), !group.contains(targetID) else { return false }
    let destination: UUID
    switch tier {
    case .global:
      guard globalPinnedTabIDs.count + group.tabIDs.filter({ !globalPinnedTabIDs.contains($0) }).count
        <= Self.globalPinnedTabLimit,
        let owner = spaceID(containing: group.leftTabID) else { return false }
      destination = owner
    case .space(let id), .temporary(let id): destination = id
    }
    guard index(of: destination) != nil,
          targetID.map({ tabIDs(in: tier).contains($0) }) ?? true else { return false }
    _ = endSplit(keeping: tabID)
    for id in group.tabIDs { _ = moveTab(id, to: tier, before: targetID) }
    spaces[index(of: destination)!].splitGroups.append(group)
    validateInvariants()
    return true
  }

  public var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

  public func space(withID id: UUID) -> BrowserSpace? {
    spaces.first { $0.id == id }
  }

  public func tab(withID id: UUID) -> BrowserTab? {
    tabsByID[id]
  }

  public func tabs(in spaceID: UUID) -> [BrowserTab] {
    guard let space = space(withID: spaceID) else { return [] }
    return space.tabIDs.compactMap { tabsByID[$0] }
  }

  public func index(of tabID: UUID, in spaceID: UUID) -> Int? {
    space(withID: spaceID)?.tabIDs.firstIndex(of: tabID)
  }

  public func spaceID(containing tabID: UUID) -> UUID? {
    spaces.first { $0.tabIDs.contains(tabID) }?.id
  }

  public func index(of spaceID: UUID) -> Int? {
    spaces.firstIndex { $0.id == spaceID }
  }

  // MARK: - Space lifecycle

  /// Appends a new Space with exactly one selected tab.
  @discardableResult
  public mutating func createSpace(
    initialTab: BrowserTab,
    name: String? = nil,
    select: Bool = true
  ) -> UUID? {
    guard tabsByID[initialTab.id] == nil,
      !spaces.contains(where: { $0.tabIDs.contains(initialTab.id) })
    else { return nil }

    let spaceID = UUID()
    let defaultName = name ?? "Space \(spaces.count + 1)"
    let space = BrowserSpace(
      id: spaceID,
      name: Self.safeSpaceName(defaultName, fallback: "Space \(spaces.count + 1)"),
      tabIDs: [initialTab.id],
      selectedTabID: initialTab.id,
      stableTabStack: [initialTab.id])
    spaces.append(space)
    tabsByID[initialTab.id] = initialTab
    if select {
      selectedSpaceID = spaceID
      selectedGlobalTabID = nil
    }
    validateInvariants()
    return spaceID
  }

  /// Trims surrounding whitespace. An empty name is rejected, leaving the
  /// existing name unchanged; this keeps the UI's current name a safe default.
  @discardableResult
  public mutating func renameSpace(id: UUID, name: String) -> Bool {
    guard let index = index(of: id) else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard spaces[index].name != trimmed else { return false }
    spaces[index].name = trimmed
    validateInvariants()
    return true
  }

  @discardableResult
  public mutating func setSpaceIcon(id: UUID, icon: BrowserSpaceIcon) -> Bool {
    guard let index = index(of: id), spaces[index].icon != icon else { return false }
    spaces[index].icon = icon
    return true
  }

  /// Selects an existing Space. A selected top pin stays effective across
  /// Spaces; otherwise the destination Space's selected tab becomes effective.
  /// The caller handles runtime focus and surface transition.
  @discardableResult
  public mutating func selectSpace(id: UUID) -> Bool {
    guard spaces.contains(where: { $0.id == id }) else { return false }
    guard selectedSpaceID != id else { return false }
    selectedSpaceID = id
    if selectedGlobalTabID == nil,
      let selectedTabID = space(withID: id)?.selectedTabID {
      tabsByID[selectedTabID]?.lastActivatedAt = Date()
    }
    validateInvariants()
    return true
  }

  // MARK: - Tab lifecycle

  /// New tabs go at the front unless a popup supplies a source tab.
  public func newTabInsertionIndex(in spaceID: UUID, after sourceTabID: UUID? = nil) -> Int {
    sourceTabID
      .flatMap { index(of: $0, in: spaceID) }
      .map { $0 + 1 } ?? 0
  }

  /// Inserts a new tab into a specific Space. Selecting is allowed only for the
  /// currently selected Space; callers that need a cross-Space selection must
  /// explicitly select the Space first.
  @discardableResult
  public mutating func insertTab(
    _ tab: BrowserTab,
    in spaceID: UUID,
    at index: Int,
    select: Bool
  ) -> Bool {
    guard tabsByID[tab.id] == nil,
      let spaceIndex = self.index(of: spaceID)
    else { return false }
    guard !select || selectedSpaceID == spaceID else { return false }

    let clamped = min(max(index, 0), spaces[spaceIndex].tabIDs.count)
    spaces[spaceIndex].tabIDs.insert(tab.id, at: clamped)
    tabsByID[tab.id] = tab
    recordStableTab(tab.id, in: spaceIndex)
    if select || spaces[spaceIndex].selectedTabID == nil {
      spaces[spaceIndex].selectedTabID = tab.id
      if select { selectedGlobalTabID = nil }
    }
    validateInvariants()
    return true
  }

  @discardableResult
  public mutating func appendTab(_ tab: BrowserTab, in spaceID: UUID, select: Bool) -> Bool {
    insertTab(tab, in: spaceID, at: space(withID: spaceID)?.tabIDs.count ?? 0, select: select)
  }

  /// Selects a tab only when it belongs to the currently selected Space.
  @discardableResult
  public mutating func selectTab(id: UUID) -> Bool {
    if globalPinnedTabIDs.contains(id) {
      guard selectedTabID != id else { return false }
      selectedGlobalTabID = id
      tabsByID[id]?.lastActivatedAt = Date()
      if let ownerIndex = spaceID(containing: id).flatMap(index(of:)) {
        recordStableTab(id, in: ownerIndex)
      }
      validateInvariants()
      return true
    }
    guard let spaceIndex = index(of: selectedSpaceID),
      spaces[spaceIndex].tabIDs.contains(id)
    else { return false }
    guard selectedTabID != id else { return false }
    spaces[spaceIndex].selectedTabID = id
    selectedGlobalTabID = nil
    tabsByID[id]?.lastActivatedAt = Date()
    recordStableTab(id, in: spaceIndex)
    validateInvariants()
    return true
  }

  /// Explicitly selects a Space and a tab in one domain operation. This is the
  /// only pure-model escape hatch for a foreign-Space tab.
  @discardableResult
  public mutating func select(spaceID: UUID, tabID: UUID) -> Bool {
    guard let spaceIndex = index(of: spaceID),
      spaces[spaceIndex].tabIDs.contains(tabID)
    else { return false }

    let changed = selectedGlobalTabID != nil || selectedSpaceID != spaceID || spaces[spaceIndex].selectedTabID != tabID
    selectedSpaceID = spaceID
    spaces[spaceIndex].selectedTabID = tabID
    selectedGlobalTabID = nil
    tabsByID[tabID]?.lastActivatedAt = Date()
    recordStableTab(tabID, in: spaceIndex)
    validateInvariants()
    return changed
  }

  @discardableResult
  public mutating func selectCurrentTab(at index: Int) -> Bool {
    guard currentTabIDs.indices.contains(index) else { return false }
    return selectTab(id: currentTabIDs[index])
  }

  @discardableResult
  public mutating func selectLastCurrentTab() -> Bool {
    guard let id = currentTabIDs.last else { return false }
    return selectTab(id: id)
  }

  /// Applies metadata from the runtime to exactly one domain tab.
  @discardableResult
  public mutating func refresh(_ tab: BrowserTab) -> Bool {
    guard tabsByID[tab.id] != nil, tabsByID[tab.id] != tab else { return false }
    tabsByID[tab.id] = tab
    validateInvariants()
    return true
  }

  /// Removes one tab from its owning Space and applies the selection policy
  /// within that Space only.
  @discardableResult
  public mutating func close(
    _ tabID: UUID,
    reason: WorkspaceTabCloseReason
  ) -> WorkspaceTabCloseResult {
    guard let spaceID = spaceID(containing: tabID),
      let spaceIndex = index(of: spaceID),
      let tabIndex = spaces[spaceIndex].tabIDs.firstIndex(of: tabID),
      let tab = tabsByID[tabID]
    else {
      return WorkspaceTabCloseResult(
        outcome: .unknownTab,
        spaceID: nil,
        snapshot: nil,
        needsReplacementTab: false)
    }

    let wasSelected = spaces[spaceIndex].selectedTabID == tabID
    let wasEffectiveSelection = selectedTabID == tabID
    var snapshot: ClosedTabSnapshot?
    if reason == .userClosed, tab.url != nil {
      snapshot = ClosedTabSnapshot(
        url: tab.url,
        title: tab.title,
        spaceID: spaceID,
        originalIndex: tabIndex)
      recentlyClosed.append(snapshot!)
      if recentlyClosed.count > Self.recentlyClosedLimit {
        recentlyClosed.removeFirst(recentlyClosed.count - Self.recentlyClosedLimit)
      }
    }

    spaces[spaceIndex].tabIDs.remove(at: tabIndex)
    spaces[spaceIndex].splitGroups.removeAll { $0.contains(tabID) }
    spaces[spaceIndex].pinnedTabIDs.removeAll { $0 == tabID }
    globalPinnedTabIDs.removeAll { $0 == tabID }
    if selectedGlobalTabID == tabID { selectedGlobalTabID = nil }
    tabsByID.removeValue(forKey: tabID)

    var nextStableID: UUID?
    if reason == .userClosed && wasEffectiveSelection {
      var stack = spaces[spaceIndex].stableTabStack
      if Set(stack).count != stack.count {
        stack.removeAll()
      } else {
        stack.removeAll { $0 == tabID }
        while let candidate = stack.popLast() {
          if spaces[spaceIndex].tabIDs.contains(candidate), tabsByID[candidate] != nil {
            nextStableID = candidate
            stack.append(candidate)
            break
          }
        }
      }
      spaces[spaceIndex].stableTabStack = stack
    }

    if spaces[spaceIndex].tabIDs.isEmpty {
      spaces[spaceIndex].selectedTabID = nil
      validateInvariants()
      return WorkspaceTabCloseResult(
        outcome: .removedLast,
        spaceID: spaceID,
        snapshot: snapshot,
        needsReplacementTab: reason == .userClosed)
    }

    guard wasSelected else {
      validateInvariants()
      return WorkspaceTabCloseResult(
        outcome: .removedSelectionUnchanged,
        spaceID: spaceID,
        snapshot: snapshot,
        needsReplacementTab: false)
    }

    let nextID: UUID
    if reason == .userClosed && wasEffectiveSelection {
      nextID = nextStableID
        ?? tabIDs(in: .temporary(spaceID)).first
        ?? spaces[spaceIndex].tabIDs[0]
    } else {
      let nextIndex = min(tabIndex, spaces[spaceIndex].tabIDs.count - 1)
      nextID = spaces[spaceIndex].tabIDs[nextIndex]
    }
    spaces[spaceIndex].selectedTabID = nextID
    validateInvariants()
    return WorkspaceTabCloseResult(
      outcome: .removedSelectionMoved(to: nextID),
      spaceID: spaceID,
      snapshot: snapshot,
      needsReplacementTab: false)
  }

  /// Inserts a fresh tab at a closed snapshot's original index, switches to
  /// that Space, and selects the new tab. The runtime owner creates the new
  /// session separately.
  @discardableResult
  public mutating func restoreTab(
    _ tab: BrowserTab,
    from snapshot: ClosedTabSnapshot
  ) -> Bool {
    guard tabsByID[tab.id] == nil,
      let spaceIndex = index(of: snapshot.spaceID)
    else { return false }

    let space = spaces[spaceIndex]
    let index = min(max(snapshot.originalIndex, 0), space.tabIDs.count)
    spaces[spaceIndex].tabIDs.insert(tab.id, at: index)
    spaces[spaceIndex].selectedTabID = tab.id
    tabsByID[tab.id] = tab
    recordStableTab(tab.id, in: spaceIndex)
    selectedSpaceID = snapshot.spaceID
    selectedGlobalTabID = nil
    validateInvariants()
    return true
  }

  @discardableResult
  public mutating func popRecentlyClosed() -> ClosedTabSnapshot? {
    recentlyClosed.popLast()
  }

  /// Moves a tab into a pin tier and places it before the indicated tab, or at
  /// the end when `before` is nil. All three visible orders are durable.
  @discardableResult
  public mutating func moveTab(_ tabID: UUID, to tier: TabTier, before targetID: UUID? = nil) -> Bool {
    guard let ownerID = spaceID(containing: tabID),
      let ownerIndex = index(of: ownerID),
      tabsByID[tabID] != nil
    else { return false }
    if case .global = tier,
      !globalPinnedTabIDs.contains(tabID),
      globalPinnedTabIDs.count >= Self.globalPinnedTabLimit { return false }

    let destinationSpaceID: UUID
    switch tier {
    case .global: destinationSpaceID = ownerID
    case .space(let id), .temporary(let id):
      guard index(of: id) != nil else { return false }
      destinationSpaceID = id
    }
    if let targetID {
      guard targetID != tabID,
        tabIDs(in: tier).contains(targetID)
      else { return false }
    }

    let wasSelected = selectedTabID == tabID
    spaces[ownerIndex].splitGroups.removeAll { $0.contains(tabID) }
    spaces[ownerIndex].tabIDs.removeAll { $0 == tabID }
    spaces[ownerIndex].pinnedTabIDs.removeAll { $0 == tabID }
    globalPinnedTabIDs.removeAll { $0 == tabID }

    let destinationIndex = index(of: destinationSpaceID)!
    if ownerID != destinationSpaceID {
      if spaces[ownerIndex].tabIDs.isEmpty {
        let replacement = BrowserTab()
        tabsByID[replacement.id] = replacement
        spaces[ownerIndex].tabIDs.append(replacement.id)
      }
      if spaces[ownerIndex].selectedTabID == tabID {
        spaces[ownerIndex].selectedTabID = spaces[ownerIndex].tabIDs.first
      }
    }
    if !spaces[destinationIndex].tabIDs.contains(tabID) {
      spaces[destinationIndex].tabIDs.append(tabID)
    }

    switch tier {
    case .global:
      let index = targetID.flatMap { globalPinnedTabIDs.firstIndex(of: $0) } ?? globalPinnedTabIDs.count
      globalPinnedTabIDs.insert(tabID, at: index)
    case .space:
      let pins = spaces[destinationIndex].pinnedTabIDs
      let index = targetID.flatMap { pins.firstIndex(of: $0) } ?? pins.count
      spaces[destinationIndex].pinnedTabIDs.insert(tabID, at: index)
    case .temporary:
      break
    }

    // The underlying per-Space order is used by keyboard selection and close
    // fallback. Rebuild it from the visible pin and temporary orders.
    if case .temporary = tier {
      let pins = spaces[destinationIndex].pinnedTabIDs
      var temporary = spaces[destinationIndex].tabIDs.filter {
        !pins.contains($0) && !globalPinnedTabIDs.contains($0) && $0 != tabID
      }
      let insertAt = targetID.flatMap { temporary.firstIndex(of: $0) } ?? temporary.count
      temporary.insert(tabID, at: insertAt)
      spaces[destinationIndex].tabIDs = pins + temporary + spaces[destinationIndex].tabIDs.filter {
        globalPinnedTabIDs.contains($0)
      }
    } else {
      let ids = spaces[destinationIndex].tabIDs
      spaces[destinationIndex].tabIDs = spaces[destinationIndex].pinnedTabIDs
        + ids.filter { !spaces[destinationIndex].pinnedTabIDs.contains($0) }
    }

    if wasSelected {
      if case .global = tier {
        selectedGlobalTabID = tabID
      } else {
        selectedGlobalTabID = nil
        selectedSpaceID = destinationSpaceID
        spaces[destinationIndex].selectedTabID = tabID
      }
    } else if spaces[destinationIndex].selectedTabID == nil {
      spaces[destinationIndex].selectedTabID = tabID
    }
    if selectedGlobalTabID == tabID, !globalPinnedTabIDs.contains(tabID) {
      selectedGlobalTabID = nil
    }
    validateInvariants()
    return true
  }

  /// Canonical sidebar names: top pin (`global`) stays across Spaces;
  /// space pin (`space`) belongs to one Space; temporary (`temporary`) is the
  /// default tier for new tabs and will later support idle expiration.
  public enum TabTier: Hashable, Sendable {
    case global
    case space(UUID)
    case temporary(UUID)
  }

  public func tabIDs(in tier: TabTier) -> [UUID] {
    switch tier {
    case .global: return globalPinnedTabIDs
    case .space(let id): return space(withID: id)?.pinnedTabIDs ?? []
    case .temporary(let id):
      guard let space = space(withID: id) else { return [] }
      return space.tabIDs.filter { !space.pinnedTabIDs.contains($0) && !globalPinnedTabIDs.contains($0) }
    }
  }

  // MARK: - Invariants

  /// Public for deterministic unit tests and diagnostics. It never consults a
  /// runtime object and therefore cannot be made false by a CEF callback.
  @discardableResult
  public func validateInvariants() -> Bool {
    guard !spaces.isEmpty,
      spaces.contains(where: { $0.id == selectedSpaceID })
    else { return false }

    var seen = Set<UUID>()
    guard globalPinnedTabIDs.count <= Self.globalPinnedTabLimit,
      Set(globalPinnedTabIDs).count == globalPinnedTabIDs.count,
      selectedGlobalTabID.map({ globalPinnedTabIDs.contains($0) }) ?? true
    else { return false }
    var groupIDs = Set<UUID>()
    for space in spaces {
      var groupedTabs = Set<UUID>()
      for group in space.splitGroups {
        guard Self.validGroup(group, in: space, globals: globalPinnedTabIDs),
              groupIDs.insert(group.id).inserted, groupedTabs.isDisjoint(with: group.tabIDs) else { return false }
        groupedTabs.formUnion(group.tabIDs)
      }
      guard Set(space.tabIDs).count == space.tabIDs.count else { return false }
      guard Set(space.pinnedTabIDs).count == space.pinnedTabIDs.count,
        space.pinnedTabIDs.allSatisfy({ space.tabIDs.contains($0) && !globalPinnedTabIDs.contains($0) })
      else { return false }
      for tabID in space.tabIDs {
        guard tabsByID[tabID] != nil, seen.insert(tabID).inserted else { return false }
      }
      if let selectedTabID = space.selectedTabID,
        !space.tabIDs.contains(selectedTabID)
      {
        return false
      }
    }
    guard seen == Set(tabsByID.keys) else { return false }
    guard globalPinnedTabIDs.allSatisfy({ seen.contains($0) }) else { return false }
    return true
  }

  private static func normalizedInitialSpaceName(_ name: String) -> String {
    safeSpaceName(name, fallback: "Main")
  }

  private mutating func recordStableTab(_ tabID: UUID, in spaceIndex: Int) {
    spaces[spaceIndex].stableTabStack.removeAll { $0 == tabID }
    spaces[spaceIndex].stableTabStack.append(tabID)
    if let groupIndex = spaces[spaceIndex].splitGroups.firstIndex(where: { $0.contains(tabID) }) {
      spaces[spaceIndex].splitGroups[groupIndex].focusedTabID = tabID
    }
  }

  private static func validGroup(_ group: BrowserSplitLayout, in space: BrowserSpace, globals: [UUID]) -> Bool {
    Set(group.tabIDs).count == group.tabIDs.count && group.fraction.isFinite && group.fraction > 0 && group.fraction < 1
      && group.tabIDs.allSatisfy({ space.tabIDs.contains($0) })
      && group.tabIDs.allSatisfy { globals.contains($0) == globals.contains(group.leftTabID)
        && space.pinnedTabIDs.contains($0) == space.pinnedTabIDs.contains(group.leftTabID) }
      && (group.middleTabID == nil || (group.secondFraction.map {
        $0.isFinite && $0 > group.fraction && $0 < 1
      } ?? true))
      && (group.focusedTabID.map { group.contains($0) } ?? true)
  }

  private static func safeSpaceName(_ name: String, fallback: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}
