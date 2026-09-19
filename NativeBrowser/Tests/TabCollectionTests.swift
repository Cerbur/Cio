//
//  TabCollectionTests.swift
//  NativeBrowserTests
//
//  The Milestone 3 tab model, tested without Chromium.
//
//  TabCollection is the entire tab *policy* - order, selection after a close,
//  the recently-closed stack, and the difference between an ordinary close and a
//  termination close - so these tests cover the ordering rules the session
//  manager delegates to. They need no application, no window and no CEF: the
//  target is a standalone logic bundle (see project.yml).
//
//  What is deliberately NOT here: anything that needs a real CefBrowser. Session
//  retention until OnBeforeClose, distinct browser identity and the parallel
//  multi-browser shutdown are covered by the --tabs-self-test integration run in
//  Scripts/verify_milestone3.sh.
//

import XCTest

final class TabCollectionTests: XCTestCase {
  private func url(_ string: String) -> URL {
    URL(string: string)!
  }

  private func tab(_ title: String, _ urlString: String? = nil) -> BrowserTab {
    BrowserTab(title: title, url: urlString.map(url))
  }

  private func workspace(_ titles: [String]) -> TabCollection {
    var collection = TabCollection.workspace(
      initialTab: tab(titles[0], "https://example.com/0"))
    for (index, title) in titles.dropFirst().enumerated() {
      collection.append(tab(title, "https://example.com/\(index + 1)"), select: false)
    }
    return collection
  }

  // MARK: - 1. Initial workspace

  func testInitialWorkspaceContainsExactlyOneSelectedTab() {
    let initial = BrowserTab(title: "Home", url: url("https://example.com/"))
    let collection = TabCollection.workspace(initialTab: initial)

    XCTAssertEqual(collection.tabs.count, 1)
    XCTAssertEqual(collection.selectedTabID, initial.id)
    XCTAssertEqual(collection.selectedTab?.id, initial.id)
    XCTAssertTrue(collection.recentlyClosed.isEmpty)
    XCTAssertFalse(collection.canReopenClosedTab)
  }

  // MARK: - 2. Creating a tab appends it

  func testCreatingATabAppendsItAtTheEnd() {
    var collection = workspace(["A", "B"])
    let created = tab("C", "https://example.com/c")
    collection.append(created, select: true)

    XCTAssertEqual(collection.tabs.map(\.title), ["A", "B", "C"])
    XCTAssertEqual(collection.selectedTabID, created.id)
  }

  func testAppendWithoutSelectingLeavesTheSelectionAlone() {
    var collection = workspace(["A", "B"])
    collection.append(tab("C", "https://example.com/c"), select: false)

    XCTAssertEqual(collection.tabs.count, 3)
    XCTAssertEqual(collection.selectedTab?.title, "A")
  }

  // MARK: - 3. Identifiers are unique

  func testCreatedTabIdentifiersAreUnique() {
    var collection = TabCollection.workspace(initialTab: tab("A", "https://example.com/a"))
    for index in 0..<25 {
      collection.append(tab("T\(index)", "https://example.com/\(index)"), select: false)
    }

    let identifiers = collection.tabs.map(\.id)
    XCTAssertEqual(identifiers.count, 26)
    XCTAssertEqual(Set(identifiers).count, identifiers.count)
  }

  // MARK: - 4. Selecting

  func testSelectingATabChangesTheSelection() {
    var collection = workspace(["A", "B", "C"])
    let second = collection.tabs[1].id

    XCTAssertTrue(collection.select(second))
    XCTAssertEqual(collection.selectedTabID, second)
    // Selecting again is a no-op rather than a second change.
    XCTAssertFalse(collection.select(second))
    XCTAssertEqual(collection.selectedTabID, second)
  }

  func testSelectingByPositionAndLast() {
    var collection = workspace(["A", "B", "C"])

    XCTAssertTrue(collection.selectTab(at: 2))
    XCTAssertEqual(collection.selectedTab?.title, "C")
    XCTAssertFalse(collection.selectTab(at: 9))
    XCTAssertEqual(collection.selectedTab?.title, "C")
  }

  func testSelectingAnUnknownTabIsSafe() {
    var collection = workspace(["A"])
    XCTAssertFalse(collection.select(UUID()))
    XCTAssertEqual(collection.selectedTab?.title, "A")
  }

  // MARK: - 5 and 6. Selection after closing the selected tab

  func testClosingSelectedTabChoosesTheRightNeighbour() {
    var collection = workspace(["A", "B", "C"])
    let middle = collection.tabs[1].id
    XCTAssertTrue(collection.select(middle))

    let result = collection.close(middle, reason: .userClosed)

    XCTAssertEqual(result.outcome, .removedSelectionMoved(to: collection.tabs[1].id))
    XCTAssertEqual(collection.selectedTab?.title, "C")
    XCTAssertEqual(collection.tabs.map(\.title), ["A", "C"])
  }

  func testClosingSelectedLastTabChoosesTheLeftNeighbour() {
    var collection = workspace(["A", "B", "C"])
    let last = collection.tabs[2].id
    XCTAssertTrue(collection.select(last))

    let result = collection.close(last, reason: .userClosed)

    XCTAssertEqual(result.outcome, .removedSelectionMoved(to: collection.tabs[1].id))
    XCTAssertEqual(collection.selectedTab?.title, "B")
    XCTAssertEqual(collection.tabs.map(\.title), ["A", "B"])
  }

  // MARK: - 7. Closing a background tab

  func testClosingABackgroundTabPreservesTheSelection() {
    var collection = workspace(["A", "B", "C"])
    let selected = collection.tabs[2].id
    XCTAssertTrue(collection.select(selected))

    let result = collection.close(collection.tabs[1].id, reason: .userClosed)

    XCTAssertEqual(result.outcome, .removedSelectionUnchanged)
    XCTAssertEqual(collection.selectedTabID, selected)
    XCTAssertEqual(collection.tabs.map(\.title), ["A", "C"])
  }

  func testClosingABackgroundTabBeforeTheSelectionKeepsTheSameTabSelected() {
    var collection = workspace(["A", "B", "C"])
    let selected = collection.tabs[2].id
    XCTAssertTrue(collection.select(selected))

    _ = collection.close(collection.tabs[0].id, reason: .userClosed)

    XCTAssertEqual(collection.selectedTabID, selected)
    XCTAssertEqual(collection.selectedTab?.title, "C")
  }

  // MARK: - 8 and 9. The last tab: user close vs application termination

  func testClosingTheLastTabAsksForAReplacement() {
    var collection = workspace(["A"])
    let only = collection.tabs[0].id

    let result = collection.close(only, reason: .userClosed)

    XCTAssertEqual(result.outcome, .removedLast)
    XCTAssertTrue(result.needsReplacementTab)
    XCTAssertTrue(collection.isEmpty)
    XCTAssertNil(collection.selectedTabID)
  }

  func testTerminationCloseNeverAsksForAReplacement() {
    var collection = workspace(["A", "B", "C"])

    for id in collection.tabIDs {
      let result = collection.close(id, reason: .applicationTerminating)
      XCTAssertFalse(
        result.needsReplacementTab,
        "application termination must never create a replacement tab")
    }

    XCTAssertTrue(collection.isEmpty)
    XCTAssertNil(collection.selectedTabID)
  }

  func testTerminationCloseDoesNotRecordRecentlyClosedTabs() {
    var collection = workspace(["A", "B"])
    for id in collection.tabIDs {
      _ = collection.close(id, reason: .applicationTerminating)
    }

    XCTAssertTrue(
      collection.recentlyClosed.isEmpty,
      "quitting the application must not fill the recently closed stack")
    XCTAssertFalse(collection.canReopenClosedTab)
  }

  // MARK: - 10. Recently closed

  func testClosingATabRecordsASnapshot() {
    var collection = workspace(["A", "B"])
    let second = collection.tabs[1]
    XCTAssertTrue(collection.select(second.id))

    let result = collection.close(second.id, reason: .userClosed)

    XCTAssertEqual(result.snapshot?.url, second.url)
    XCTAssertEqual(result.snapshot?.title, "B")
    XCTAssertEqual(result.snapshot?.originalIndex, 1)
    XCTAssertEqual(collection.recentlyClosed.count, 1)
    XCTAssertTrue(collection.canReopenClosedTab)
  }

  func testATabWithNoCommittedURLIsNotRemembered() {
    var collection = TabCollection.workspace(initialTab: BrowserTab(title: ""))
    let only = collection.tabs[0].id

    let result = collection.close(only, reason: .userClosed)

    XCTAssertNil(result.snapshot, "a tab that never reached a page is not worth reopening")
    XCTAssertTrue(collection.recentlyClosed.isEmpty)
  }

  func testTheRecentlyClosedStackIsBounded() {
    var collection = TabCollection.workspace(initialTab: tab("first", "https://example.com/first"))
    for index in 0..<40 {
      let created = tab("t\(index)", "https://example.com/\(index)")
      collection.append(created, select: true)
      _ = collection.close(created.id, reason: .userClosed)
    }

    XCTAssertEqual(collection.recentlyClosed.count, TabCollection.recentlyClosedLimit)
    // The newest entry survives, the oldest ones were dropped.
    XCTAssertEqual(collection.recentlyClosed.last?.title, "t39")
  }

  // MARK: - 11. Cmd-Shift-T semantics

  func testReopeningReturnsTheMostRecentlyClosedSnapshotFirst() {
    var collection = workspace(["A", "B", "C"])
    _ = collection.close(collection.tabs[2].id, reason: .userClosed)
    _ = collection.close(collection.tabs[1].id, reason: .userClosed)

    XCTAssertEqual(collection.popRecentlyClosed()?.title, "B")
    XCTAssertEqual(collection.popRecentlyClosed()?.title, "C")
    XCTAssertNil(collection.popRecentlyClosed())
    XCTAssertFalse(collection.canReopenClosedTab)
  }

  func testReopeningWithNothingClosedIsSafe() {
    var collection = workspace(["A"])
    XCTAssertNil(collection.popRecentlyClosed())
    XCTAssertEqual(collection.tabs.count, 1)
  }

  func testReopeningRestoresTheTabNearItsOriginalPosition() {
    var collection = workspace(["A", "B", "C"])
    let middle = collection.tabs[1]
    _ = collection.close(middle.id, reason: .userClosed)

    guard let snapshot = collection.popRecentlyClosed() else {
      return XCTFail("the closed tab should have been recorded")
    }
    let restored = BrowserTab(title: snapshot.title, url: snapshot.url)
    collection.insert(restored, at: snapshot.originalIndex, select: true)

    XCTAssertEqual(collection.tabs.map(\.title), ["A", "B", "C"])
    XCTAssertEqual(collection.selectedTabID, restored.id)
  }

  func testInsertingBeyondTheEndClampsToTheEnd() {
    var collection = workspace(["A"])
    let extra = tab("Z", "https://example.com/z")
    collection.insert(extra, at: 99, select: false)

    XCTAssertEqual(collection.tabs.map(\.title), ["A", "Z"])
  }

  // MARK: - 12. A restored tab is a new tab

  func testRestoredTabGetsANewIdentity() {
    var collection = workspace(["A"])
    let original = collection.tabs[0]
    _ = collection.close(original.id, reason: .userClosed)

    guard let snapshot = collection.popRecentlyClosed() else {
      return XCTFail("the closed tab should have been recorded")
    }
    let restored = BrowserTab(title: snapshot.title, url: snapshot.url)
    collection.insert(restored, at: snapshot.originalIndex, select: true)

    XCTAssertNotEqual(restored.id, original.id, "reopening must mint a new tab identity")
    XCTAssertEqual(collection.tabs.count, 1)
    XCTAssertEqual(collection.selectedTabID, restored.id)
  }

  // MARK: - 13. Deterministic order

  func testOrderIsDeterministicAcrossRepeatedOperations() {
    var collection = workspace(["A", "B", "C", "D"])
    let initialIDs = collection.tabIDs

    // Removing a tab moves nothing else: the survivors keep their identity and
    // their relative order, so the list is never re-sorted.
    _ = collection.close(initialIDs[1], reason: .userClosed)
    XCTAssertEqual(collection.tabIDs, [initialIDs[0], initialIDs[2], initialIDs[3]])
    XCTAssertEqual(collection.tabs.map(\.title), ["A", "C", "D"])

    // Appending always goes to the end.
    let appended = tab("E", "https://example.com/e")
    collection.append(appended, select: true)
    XCTAssertEqual(collection.tabIDs, [initialIDs[0], initialIDs[2], initialIDs[3], appended.id])
    XCTAssertEqual(collection.selectedTabID, appended.id)

    // A restore goes back to the index the tab occupied when it closed.
    guard let snapshot = collection.popRecentlyClosed() else {
      return XCTFail("the closed tab should have been recorded")
    }
    let restored = BrowserTab(title: snapshot.title, url: snapshot.url)
    collection.insert(restored, at: snapshot.originalIndex, select: false)

    XCTAssertEqual(collection.tabs.map(\.title), ["A", "B", "C", "D", "E"])
    XCTAssertEqual(collection.selectedTabID, appended.id, "a background restore keeps the selection")
  }

  func testTabMetadataRefreshKeepsPositionAndIdentity() {
    var collection = workspace(["A", "B"])
    let secondID = collection.tabs[1].id

    var refreshed = collection.tabs[1]
    refreshed.title = "B loaded"
    refreshed.url = url("https://example.com/b")
    refreshed.isLoading = true
    XCTAssertTrue(collection.refresh(refreshed))

    XCTAssertEqual(collection.tabs.map(\.id), [collection.tabs[0].id, secondID])
    XCTAssertEqual(collection.tabs[1].title, "B loaded")
    XCTAssertTrue(collection.tabs[1].isLoading)
    // Refreshing with identical metadata reports no change.
    XCTAssertFalse(collection.refresh(refreshed))
  }

  // MARK: - 14. Unknown and already closed tabs

  func testClosingAnUnknownTabIsSafe() {
    var collection = workspace(["A", "B"])
    let before = collection.tabs
    let selection = collection.selectedTabID

    let result = collection.close(UUID(), reason: .userClosed)

    XCTAssertEqual(result.outcome, .unknownTab)
    XCTAssertNil(result.snapshot)
    XCTAssertFalse(result.needsReplacementTab)
    XCTAssertEqual(collection.tabs, before)
    XCTAssertEqual(collection.selectedTabID, selection)
  }

  func testClosingTheSameTabTwiceIsSafe() {
    var collection = workspace(["A", "B"])
    let victim = collection.tabs[1].id

    let first = collection.close(victim, reason: .userClosed)
    let second = collection.close(victim, reason: .userClosed)

    XCTAssertEqual(first.outcome, .removedSelectionUnchanged)
    XCTAssertEqual(second.outcome, .unknownTab)
    XCTAssertEqual(collection.recentlyClosed.count, 1, "the second close must not record again")
    XCTAssertEqual(collection.tabs.map(\.title), ["A"])
  }

  // MARK: - Sidebar label

  func testDisplayTitleFallsBackFromTitleToHostToNewTab() {
    XCTAssertEqual(
      BrowserTab(title: "  Example Domain  ", url: url("https://example.com/x")).displayTitle,
      "Example Domain")
    XCTAssertEqual(
      BrowserTab(title: "   ", url: url("https://example.com/x")).displayTitle,
      "example.com")
    XCTAssertEqual(BrowserTab(title: "", url: nil).displayTitle, BrowserTab.untitled)
    XCTAssertEqual(BrowserTab.untitled, "New Tab")
  }
}
