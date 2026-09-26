//
//  WorkspaceCollection.swift
//  NativeBrowser
//
//  Pure workspace/domain state for Milestone 4. This file has no AppKit or CEF
//  dependency and is the only source of truth for Spaces, tab membership,
//  ordering, selection and recently-closed policy.
//

import Foundation

/// Why a tab is being removed from the workspace.
enum WorkspaceTabCloseReason: Equatable, Sendable {
  case userClosed
  case applicationTerminating
}

/// What happened to a tab's selection when it was removed.
enum WorkspaceTabRemovalOutcome: Equatable, Sendable {
  case unknownTab
  case removedSelectionUnchanged
  case removedSelectionMoved(to: UUID)
  case removedLast
}

/// The result the runtime owner needs after a domain close.
struct WorkspaceTabCloseResult: Equatable, Sendable {
  var outcome: WorkspaceTabRemovalOutcome
  var spaceID: UUID?
  var snapshot: ClosedTabSnapshot?
  var needsReplacementTab: Bool
}

/// All in-memory workspace relationships.
///
/// The collection owns one tab dictionary and one ordered list per Space. The
/// dictionary is an identity index only; every ordered traversal goes through a
/// Space's `tabIDs`, so Space and tab order are deterministic.
struct WorkspaceCollection: Equatable, Sendable {
  static let recentlyClosedLimit = 10
  static let globalPinnedTabLimit = 16

  private(set) var spaces: [BrowserSpace]
  private(set) var selectedSpaceID: UUID
  private(set) var tabsByID: [UUID: BrowserTab]
  private(set) var recentlyClosed: [ClosedTabSnapshot]
  private(set) var globalPinnedTabIDs: [UUID]
  private(set) var selectedGlobalTabID: UUID?

  /// Creates the normal application starting state: one Main Space, one tab,
  /// and both levels of selection pointing at that tab.
  init(initialTab: BrowserTab, spaceName: String = "Main") {
    let space = BrowserSpace(
      name: Self.normalizedInitialSpaceName(spaceName),
      tabIDs: [initialTab.id],
      selectedTabID: initialTab.id)
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
  init(restoring snapshot: WorkspaceSessionSnapshot) throws {
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
          tabIDs: orderedTabIDs,
          pinnedTabIDs: persistedSpace.pinnedTabIDs,
          selectedTabID: selectedTabID))
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

    guard globalPinnedTabIDs.count <= Self.globalPinnedTabLimit,
      Set(globalPinnedTabIDs).count == globalPinnedTabIDs.count,
      globalPinnedTabIDs.allSatisfy({ restoredTabs[$0] != nil }),
      selectedGlobalTabID.map({ globalPinnedTabIDs.contains($0) }) ?? true,
      restoredSpaces.allSatisfy({ Set($0.pinnedTabIDs).isDisjoint(with: globalPinnedTabIDs) })
    else { throw WorkspaceSessionSnapshotError.invalidPinnedTabs }

    guard validateInvariants() else {
      // The explicit checks above cover the serialized graph. Keep this final
      // assertion as a defense against future model changes that add another
      // invariant without updating the restore path.
      throw WorkspaceSessionSnapshotError.selectedTabNotInSpace
    }
  }

  // MARK: - Derived selection and ordering

  var selectedSpace: BrowserSpace? {
    spaces.first { $0.id == selectedSpaceID }
  }

  /// The one authoritative effective selected tab for the whole application.
  var selectedTabID: UUID? {
    selectedGlobalTabID ?? selectedSpace?.selectedTabID
  }

  var selectedTab: BrowserTab? {
    selectedTabID.flatMap { tabsByID[$0] }
  }

  var spaceIDs: [UUID] { spaces.map(\.id) }

  /// All visible tabs in deterministic Space order, then per-Space tab order.
  var allTabs: [BrowserTab] {
    spaces.flatMap { tabs(in: $0.id) }
  }

  var allTabIDs: [UUID] {
    spaces.flatMap(\.tabIDs)
  }

  var currentTabs: [BrowserTab] {
    tabs(in: selectedSpaceID)
  }

  var globalPinnedTabs: [BrowserTab] {
    globalPinnedTabIDs.compactMap { tabsByID[$0] }
  }

  var currentSpacePinnedTabs: [BrowserTab] {
    guard let space = selectedSpace else { return [] }
    return space.pinnedTabIDs.compactMap { tabsByID[$0] }
  }

  var currentTemporaryTabs: [BrowserTab] {
    guard let space = selectedSpace else { return [] }
    return space.tabIDs.filter { !space.pinnedTabIDs.contains($0) && !globalPinnedTabIDs.contains($0) }
      .compactMap { tabsByID[$0] }
  }

  var currentTabIDs: [UUID] {
    selectedSpace?.tabIDs ?? []
  }

  var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

  func space(withID id: UUID) -> BrowserSpace? {
    spaces.first { $0.id == id }
  }

  func tab(withID id: UUID) -> BrowserTab? {
    tabsByID[id]
  }

  func tabs(in spaceID: UUID) -> [BrowserTab] {
    guard let space = space(withID: spaceID) else { return [] }
    return space.tabIDs.compactMap { tabsByID[$0] }
  }

  func index(of tabID: UUID, in spaceID: UUID) -> Int? {
    space(withID: spaceID)?.tabIDs.firstIndex(of: tabID)
  }

  func spaceID(containing tabID: UUID) -> UUID? {
    spaces.first { $0.tabIDs.contains(tabID) }?.id
  }

  func index(of spaceID: UUID) -> Int? {
    spaces.firstIndex { $0.id == spaceID }
  }

  // MARK: - Space lifecycle

  /// Appends a new Space with exactly one selected tab.
  @discardableResult
  mutating func createSpace(
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
      selectedTabID: initialTab.id)
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
  mutating func renameSpace(id: UUID, name: String) -> Bool {
    guard let index = index(of: id) else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard spaces[index].name != trimmed else { return false }
    spaces[index].name = trimmed
    validateInvariants()
    return true
  }

  /// Selects an existing Space. A selected top pin stays effective across
  /// Spaces; otherwise the destination Space's selected tab becomes effective.
  /// The caller handles runtime focus and surface transition.
  @discardableResult
  mutating func selectSpace(id: UUID) -> Bool {
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

  /// Inserts a new tab into a specific Space. Selecting is allowed only for the
  /// currently selected Space; callers that need a cross-Space selection must
  /// explicitly select the Space first.
  @discardableResult
  mutating func insertTab(
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
    if select || spaces[spaceIndex].selectedTabID == nil {
      spaces[spaceIndex].selectedTabID = tab.id
      if select { selectedGlobalTabID = nil }
    }
    validateInvariants()
    return true
  }

  @discardableResult
  mutating func appendTab(_ tab: BrowserTab, in spaceID: UUID, select: Bool) -> Bool {
    insertTab(tab, in: spaceID, at: space(withID: spaceID)?.tabIDs.count ?? 0, select: select)
  }

  /// Selects a tab only when it belongs to the currently selected Space.
  @discardableResult
  mutating func selectTab(id: UUID) -> Bool {
    if globalPinnedTabIDs.contains(id) {
      guard selectedTabID != id else { return false }
      selectedGlobalTabID = id
      tabsByID[id]?.lastActivatedAt = Date()
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
    validateInvariants()
    return true
  }

  /// Explicitly selects a Space and a tab in one domain operation. This is the
  /// only pure-model escape hatch for a foreign-Space tab.
  @discardableResult
  mutating func select(spaceID: UUID, tabID: UUID) -> Bool {
    guard let spaceIndex = index(of: spaceID),
      spaces[spaceIndex].tabIDs.contains(tabID)
    else { return false }

    let changed = selectedGlobalTabID != nil || selectedSpaceID != spaceID || spaces[spaceIndex].selectedTabID != tabID
    selectedSpaceID = spaceID
    spaces[spaceIndex].selectedTabID = tabID
    selectedGlobalTabID = nil
    tabsByID[tabID]?.lastActivatedAt = Date()
    validateInvariants()
    return changed
  }

  @discardableResult
  mutating func selectCurrentTab(at index: Int) -> Bool {
    guard currentTabIDs.indices.contains(index) else { return false }
    return selectTab(id: currentTabIDs[index])
  }

  @discardableResult
  mutating func selectLastCurrentTab() -> Bool {
    guard let id = currentTabIDs.last else { return false }
    return selectTab(id: id)
  }

  /// Applies metadata from the runtime to exactly one domain tab.
  @discardableResult
  mutating func refresh(_ tab: BrowserTab) -> Bool {
    guard tabsByID[tab.id] != nil, tabsByID[tab.id] != tab else { return false }
    tabsByID[tab.id] = tab
    validateInvariants()
    return true
  }

  /// Removes one tab from its owning Space and applies the selection policy
  /// within that Space only.
  @discardableResult
  mutating func close(
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
    spaces[spaceIndex].pinnedTabIDs.removeAll { $0 == tabID }
    globalPinnedTabIDs.removeAll { $0 == tabID }
    if selectedGlobalTabID == tabID { selectedGlobalTabID = nil }
    tabsByID.removeValue(forKey: tabID)

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

    let nextIndex = tabIndex < spaces[spaceIndex].tabIDs.count
      ? tabIndex
      : spaces[spaceIndex].tabIDs.count - 1
    let nextID = spaces[spaceIndex].tabIDs[nextIndex]
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
  mutating func restoreTab(
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
    selectedSpaceID = snapshot.spaceID
    selectedGlobalTabID = nil
    validateInvariants()
    return true
  }

  @discardableResult
  mutating func popRecentlyClosed() -> ClosedTabSnapshot? {
    recentlyClosed.popLast()
  }

  /// Moves a tab into a pin tier and places it before the indicated tab, or at
  /// the end when `before` is nil. All three visible orders are durable.
  @discardableResult
  mutating func moveTab(_ tabID: UUID, to tier: TabTier, before targetID: UUID? = nil) -> Bool {
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
  enum TabTier: Hashable {
    case global
    case space(UUID)
    case temporary(UUID)
  }

  func tabIDs(in tier: TabTier) -> [UUID] {
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
  func validateInvariants() -> Bool {
    guard !spaces.isEmpty,
      spaces.contains(where: { $0.id == selectedSpaceID })
    else { return false }

    var seen = Set<UUID>()
    guard globalPinnedTabIDs.count <= Self.globalPinnedTabLimit,
      Set(globalPinnedTabIDs).count == globalPinnedTabIDs.count,
      selectedGlobalTabID.map({ globalPinnedTabIDs.contains($0) }) ?? true
    else { return false }
    for space in spaces {
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

  private static func safeSpaceName(_ name: String, fallback: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}
