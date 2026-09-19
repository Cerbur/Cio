//
//  TabCollection.swift
//  NativeBrowser
//
//  Pure tab ordering, selection and recently-closed policy (Milestone 3
//  sections 4, 5, 10, 20 and 22).
//
//  This is the whole of the tab *model*. BrowserSessionManager adds the runtime
//  half - one BrowserSession per tab, retained until OnBeforeClose - and owns a
//  TabCollection rather than re-implementing the ordering rules, so the rules
//  have exactly one definition and can be tested without Chromium.
//
//  Kept dependency free (Foundation only) so it compiles into both the
//  application target and the unit test bundle (see project.yml).
//

import Foundation

/// Why a tab is being removed.
///
/// The distinction is load-bearing, not cosmetic: an ordinary user close may
/// create a replacement tab and is recorded for ⌘⇧T, while closing everything
/// for application termination must do neither (Milestone 3 section 10).
enum TabCloseReason: Equatable, Sendable {
  /// The user closed the tab (⌘W or the sidebar close button).
  case userClosed
  /// The whole application is terminating and every browser is being closed.
  case applicationTerminating
}

/// What happened to the *selection* when a tab was removed.
enum TabRemovalOutcome: Equatable, Sendable {
  /// No tab with that identifier; nothing changed. Closing an unknown or
  /// already-closed tab is a no-op rather than an error.
  case unknownTab
  /// The removed tab was not selected, so the selection is unchanged.
  case removedSelectionUnchanged
  /// The removed tab was selected and this tab is now selected: the tab that was
  /// immediately to its right, or the one to its left when it was last.
  case removedSelectionMoved(to: UUID)
  /// The removed tab was the last one. Whether a replacement is created is the
  /// owner's decision - see `TabCloseResult.needsReplacementTab`.
  case removedLast
}

/// A close, expressed in the terms the owner acts on.
struct TabCloseResult: Equatable, Sendable {
  var outcome: TabRemovalOutcome
  /// The snapshot recorded for ⌘⇧T, when one was recorded. `nil` for a
  /// background tab that has not committed a URL yet, and always `nil` during
  /// application termination.
  var snapshot: ClosedTabSnapshot?
  /// True when the workspace is empty because of an *ordinary* user close, so
  /// the owner must create a fresh tab so the window stays usable. Always false
  /// for a termination close.
  var needsReplacementTab: Bool
}

/// The ordered, selected tab list plus the bounded recently-closed stack.
struct TabCollection: Equatable, Sendable {
  /// How many closed tabs are remembered. In memory only for Milestone 3: the
  /// stack is not written to disk and does not survive relaunch (section 35).
  static let recentlyClosedLimit = 10

  private(set) var tabs: [BrowserTab] = []
  private(set) var selectedTabID: UUID?
  private(set) var recentlyClosed: [ClosedTabSnapshot] = []

  init() {}

  /// The workspace the application starts with: exactly one selected tab.
  static func workspace(initialTab: BrowserTab) -> TabCollection {
    var collection = TabCollection()
    collection.append(initialTab, select: true)
    return collection
  }

  var isEmpty: Bool { tabs.isEmpty }
  var tabIDs: [UUID] { tabs.map(\.id) }
  var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }
  var selectedTab: BrowserTab? { selectedTabID.flatMap(tab(withID:)) }

  func index(of id: UUID) -> Int? {
    tabs.firstIndex { $0.id == id }
  }

  func tab(withID id: UUID) -> BrowserTab? {
    tabs.first { $0.id == id }
  }

  func tabID(at index: Int) -> UUID? {
    tabs.indices.contains(index) ? tabs[index].id : nil
  }

  // MARK: - Mutation

  /// Appends a tab at the end of the order. Returns its identifier.
  @discardableResult
  mutating func append(_ tab: BrowserTab, select: Bool) -> UUID {
    insert(tab, at: tabs.count, select: select)
  }

  /// Inserts a tab at `index` (clamped into range). Returns its identifier.
  ///
  /// Used by ⌘⇧T, which puts the restored tab back at the index it occupied
  /// when it closed.
  @discardableResult
  mutating func insert(_ tab: BrowserTab, at index: Int, select: Bool) -> UUID {
    let clamped = min(max(index, 0), tabs.count)
    tabs.insert(tab, at: clamped)
    if select || selectedTabID == nil {
      selectedTabID = tab.id
    }
    return tab.id
  }

  /// Selects `id`. Returns true when the selection actually changed.
  @discardableResult
  mutating func select(_ id: UUID) -> Bool {
    guard tab(withID: id) != nil else { return false }
    guard selectedTabID != id else { return false }
    selectedTabID = id
    if let index = index(of: id) {
      tabs[index].lastActivatedAt = Date()
    }
    return true
  }

  /// Selects the tab at `index` when there is one (⌘1…⌘8, ⌘9).
  @discardableResult
  mutating func selectTab(at index: Int) -> Bool {
    guard let id = tabID(at: index) else { return false }
    return select(id)
  }

  /// Applies refreshed metadata reported by the tab's Chromium browser.
  ///
  /// The metadata's `id` selects the tab; everything else replaces the stored
  /// value. Returns true when something changed.
  @discardableResult
  mutating func refresh(_ tab: BrowserTab) -> Bool {
    guard let index = index(of: tab.id) else { return false }
    guard tabs[index] != tab else { return false }
    tabs[index] = tab
    return true
  }

  /// Removes `id` from the visible order and applies the selection policy.
  @discardableResult
  mutating func close(_ id: UUID, reason: TabCloseReason) -> TabCloseResult {
    guard let index = index(of: id) else {
      return TabCloseResult(
        outcome: .unknownTab, snapshot: nil, needsReplacementTab: false)
    }
    let tab = tabs[index]
    let wasSelected = selectedTabID == id

    var snapshot: ClosedTabSnapshot?
    if reason == .userClosed, tab.url != nil {
      // Only a tab that reached a page is worth remembering; reopening an empty
      // "New Tab" is not something ⌘⇧T should offer (Milestone 3 section 4).
      snapshot = ClosedTabSnapshot(url: tab.url, title: tab.title, originalIndex: index)
      recentlyClosed.append(snapshot!)
      if recentlyClosed.count > Self.recentlyClosedLimit {
        recentlyClosed.removeFirst(recentlyClosed.count - Self.recentlyClosedLimit)
      }
    }

    tabs.remove(at: index)

    if tabs.isEmpty {
      selectedTabID = nil
      return TabCloseResult(
        outcome: .removedLast,
        snapshot: snapshot,
        // Section 10: quitting must not create a replacement tab.
        needsReplacementTab: reason == .userClosed)
    }

    guard wasSelected else {
      return TabCloseResult(
        outcome: .removedSelectionUnchanged, snapshot: snapshot, needsReplacementTab: false)
    }

    // Section 20: the tab immediately to the right when there is one - after the
    // removal it sits at the same index - otherwise the tab to the left.
    let nextIndex = index < tabs.count ? index : tabs.count - 1
    selectedTabID = tabs[nextIndex].id
    return TabCloseResult(
      outcome: .removedSelectionMoved(to: tabs[nextIndex].id),
      snapshot: snapshot,
      needsReplacementTab: false)
  }

  /// Removes the oldest history beyond the bounded stack. Returns how many
  /// entries were dropped (0 in normal use).
  @discardableResult
  mutating func trimRecentlyClosed() -> Int {
    guard recentlyClosed.count > Self.recentlyClosedLimit else { return 0 }
    let excess = recentlyClosed.count - Self.recentlyClosedLimit
    recentlyClosed.removeFirst(excess)
    return excess
  }

  /// Takes the most recently closed snapshot, or nil when there is none.
  mutating func popRecentlyClosed() -> ClosedTabSnapshot? {
    recentlyClosed.popLast()
  }
}
