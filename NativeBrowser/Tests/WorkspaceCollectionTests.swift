//
//  WorkspaceCollectionTests.swift
//  NativeBrowserTests
//
//  Pure Milestone 4 Space/domain tests. These tests do not link AppKit, CEF or
//  BrowserSessionManager; they exercise the one workspace source of truth.
//

import XCTest

final class WorkspaceCollectionTests: XCTestCase {
  private func url(_ value: String) -> URL { URL(string: value)! }

  private func tab(_ title: String, _ value: String? = nil) -> BrowserTab {
    BrowserTab(title: title, url: value.map(url))
  }

  private func workspace(_ titles: [String]) -> WorkspaceCollection {
    var collection = WorkspaceCollection(
      initialTab: tab(titles[0], "https://example.com/0"))
    for (index, title) in titles.dropFirst().enumerated() {
      let created = tab(title, "https://example.com/\(index + 1)")
      XCTAssertTrue(collection.appendTab(created, in: collection.selectedSpaceID, select: false))
    }
    return collection
  }

  func testInitialWorkspaceContainsExactlyOneSpace() {
    let initial = tab("Home", "https://example.com/")
    let collection = WorkspaceCollection(initialTab: initial)

    XCTAssertEqual(collection.spaces.count, 1)
    XCTAssertEqual(collection.selectedSpace?.name, "Main")
    XCTAssertEqual(collection.selectedSpaceID, collection.spaces[0].id)
    XCTAssertEqual(collection.selectedTabID, initial.id)
    XCTAssertEqual(collection.currentTabs.map(\.id), [initial.id])
    XCTAssertTrue(collection.validateInvariants())
  }

  func testCreatingSpaceAppendsPredictablyAndSelectsItsFreshTab() {
    var collection = WorkspaceCollection(initialTab: tab("Main", "https://example.com"))
    let firstID = collection.selectedSpaceID
    let newTab = tab("Space tab", "https://example.org")

    let secondID = collection.createSpace(initialTab: newTab)

    XCTAssertNotNil(secondID)
    XCTAssertEqual(collection.spaces.map(\.name), ["Main", "Space 2"])
    XCTAssertEqual(collection.spaces.map(\.id).count, Set(collection.spaces.map(\.id)).count)
    XCTAssertEqual(collection.selectedSpaceID, secondID)
    XCTAssertNotEqual(firstID, secondID)
    XCTAssertEqual(collection.selectedTabID, newTab.id)
    XCTAssertEqual(collection.tabs(in: secondID!).map(\.id), [newTab.id])
  }

  func testSwitchingSpaceUpdatesSelectedSpace() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let newTab = tab("Other")
    let secondID = collection.createSpace(initialTab: newTab)!

    XCTAssertTrue(collection.selectSpace(id: collection.spaces[0].id))
    XCTAssertEqual(collection.selectedSpaceID, collection.spaces[0].id)
    XCTAssertTrue(collection.selectSpace(id: secondID))
    XCTAssertEqual(collection.selectedSpaceID, secondID)
    XCTAssertEqual(collection.selectedTabID, newTab.id)
  }

  func testEachSpaceRemembersItsSelectedTabIndependently() {
    var collection = WorkspaceCollection(initialTab: tab("Main A", "https://a.example"))
    let mainID = collection.selectedSpaceID
    let mainB = tab("Main B", "https://b.example")
    XCTAssertTrue(collection.appendTab(mainB, in: mainID, select: false))
    XCTAssertTrue(collection.selectTab(id: mainB.id))

    let otherTab = tab("Other A", "https://other.example/a")
    let otherID = collection.createSpace(initialTab: otherTab)!
    let otherB = tab("Other B", "https://other.example/b")
    XCTAssertTrue(collection.appendTab(otherB, in: otherID, select: true))

    XCTAssertTrue(collection.selectSpace(id: mainID))
    XCTAssertEqual(collection.selectedTabID, mainB.id)
    XCTAssertTrue(collection.selectSpace(id: otherID))
    XCTAssertEqual(collection.selectedTabID, otherB.id)
    XCTAssertTrue(collection.selectSpace(id: mainID))
    XCTAssertEqual(collection.selectedTabID, mainB.id)
  }

  func testTabsBelongToExactlyOneSpace() {
    var collection = WorkspaceCollection(initialTab: tab("A"))
    let firstSpace = collection.selectedSpaceID
    let secondTab = tab("B")
    let secondSpace = collection.createSpace(initialTab: secondTab)!

    XCTAssertEqual(collection.allTabIDs.count, Set(collection.allTabIDs).count)
    XCTAssertEqual(collection.spaceID(containing: secondTab.id), secondSpace)
    XCTAssertNotEqual(firstSpace, secondSpace)
    XCTAssertTrue(collection.validateInvariants())

    let duplicate = tab("duplicate", "https://duplicate.example")
    XCTAssertTrue(collection.appendTab(duplicate, in: firstSpace, select: false))
    XCTAssertFalse(collection.appendTab(duplicate, in: secondSpace, select: false))
    XCTAssertTrue(collection.validateInvariants())
  }

  func testCreateTabAddsOnlyToSelectedSpace() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let mainID = collection.selectedSpaceID
    let otherID = collection.createSpace(initialTab: tab("Other"))!
    XCTAssertTrue(collection.selectSpace(id: mainID))

    let created = tab("New", "https://new.example")
    XCTAssertTrue(collection.appendTab(created, in: mainID, select: true))

    XCTAssertTrue(collection.tabs(in: mainID).contains { $0.id == created.id })
    XCTAssertFalse(collection.tabs(in: otherID).contains { $0.id == created.id })
    XCTAssertEqual(collection.selectedTabID, created.id)
  }

  func testTabOrderIsIndependentPerSpace() {
    var collection = WorkspaceCollection(initialTab: tab("A"))
    let mainID = collection.selectedSpaceID
    let otherID = collection.createSpace(initialTab: tab("X"))!

    XCTAssertTrue(collection.selectSpace(id: mainID))
    XCTAssertTrue(collection.appendTab(tab("B"), in: mainID, select: false))
    XCTAssertTrue(collection.appendTab(tab("C"), in: mainID, select: false))
    XCTAssertTrue(collection.selectSpace(id: otherID))
    XCTAssertTrue(collection.appendTab(tab("Y"), in: otherID, select: false))

    XCTAssertEqual(collection.tabs(in: mainID).map(\.title), ["A", "B", "C"])
    XCTAssertEqual(collection.tabs(in: otherID).map(\.title), ["X", "Y"])
  }

  func testSelectingCurrentSpaceTabWorks() {
    var collection = workspace(["A", "B", "C"])
    let id = collection.currentTabIDs[1]

    XCTAssertTrue(collection.selectTab(id: id))
    XCTAssertEqual(collection.selectedTabID, id)
    XCTAssertFalse(collection.selectTab(id: id))
  }

  func testSelectingForeignSpaceTabIsRejected() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let mainID = collection.selectedSpaceID
    let foreignID = collection.createSpace(initialTab: tab("Foreign"))!
    let foreignTabID = collection.tabs(in: foreignID)[0].id
    XCTAssertTrue(collection.selectSpace(id: mainID))

    XCTAssertFalse(collection.selectTab(id: foreignTabID))
    XCTAssertEqual(collection.selectedSpaceID, mainID)
    XCTAssertNotEqual(collection.selectedTabID, foreignTabID)
  }

  func testExplicitSpaceAndTabSelectionIsTheOnlyForeignEscapeHatch() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let foreignID = collection.createSpace(initialTab: tab("Foreign"))!
    let foreignTabID = collection.tabs(in: foreignID)[0].id
    let mainID = collection.spaces[0].id
    XCTAssertTrue(collection.selectSpace(id: mainID))

    XCTAssertTrue(collection.select(spaceID: foreignID, tabID: foreignTabID))
    XCTAssertEqual(collection.selectedSpaceID, foreignID)
    XCTAssertEqual(collection.selectedTabID, foreignTabID)
  }

  func testClosingSelectedTabChoosesRightNeighbourInSameSpace() {
    var collection = workspace(["A", "B", "C"])
    let spaceID = collection.selectedSpaceID
    let middle = collection.currentTabIDs[1]
    XCTAssertTrue(collection.selectTab(id: middle))

    let result = collection.close(middle, reason: .userClosed)

    XCTAssertEqual(result.spaceID, spaceID)
    XCTAssertEqual(result.outcome, .removedSelectionMoved(to: collection.currentTabIDs[1]))
    XCTAssertEqual(collection.currentTabs.map(\.title), ["A", "C"])
  }

  func testClosingBackgroundTabLeavesSpaceSelectionIntact() {
    var collection = workspace(["A", "B", "C"])
    let selected = collection.currentTabIDs[2]
    XCTAssertTrue(collection.selectTab(id: selected))
    let background = collection.currentTabIDs[1]

    let result = collection.close(background, reason: .userClosed)

    XCTAssertEqual(result.outcome, .removedSelectionUnchanged)
    XCTAssertEqual(collection.selectedTabID, selected)
    XCTAssertEqual(collection.currentTabs.map(\.title), ["A", "C"])
  }

  func testClosingLastTabRequestsReplacementInItsOwnSpace() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let mainID = collection.selectedSpaceID
    let otherID = collection.createSpace(initialTab: tab("Other"))!
    let onlyOther = collection.tabs(in: otherID)[0].id
    XCTAssertTrue(collection.selectSpace(id: mainID))

    let result = collection.close(onlyOther, reason: .userClosed)
    XCTAssertEqual(result.outcome, .removedLast)
    XCTAssertTrue(result.needsReplacementTab)
    XCTAssertTrue(collection.tabs(in: otherID).isEmpty)

    let replacement = tab("replacement")
    XCTAssertTrue(collection.appendTab(replacement, in: otherID, select: false))
    XCTAssertEqual(collection.tabs(in: otherID).map(\.id), [replacement.id])
    XCTAssertEqual(collection.selectedSpaceID, mainID)
  }

  func testTerminationCloseDoesNotCreateReplacementOrRecentlyClosedEntry() {
    var collection = workspace(["A", "B"])
    let ids = collection.currentTabIDs
    for id in ids {
      let result = collection.close(id, reason: .applicationTerminating)
      XCTAssertFalse(result.needsReplacementTab)
    }

    XCTAssertTrue(collection.currentTabs.isEmpty)
    XCTAssertTrue(collection.recentlyClosed.isEmpty)
    XCTAssertNil(collection.selectedTabID)
  }

  func testRecentlyClosedSnapshotRecordsOriginSpaceAndIndex() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let spaceID = collection.selectedSpaceID
    let middle = tab("Middle", "https://middle.example")
    XCTAssertTrue(collection.appendTab(middle, in: spaceID, select: false))
    let result = collection.close(middle.id, reason: .userClosed)

    XCTAssertEqual(result.snapshot?.spaceID, spaceID)
    XCTAssertEqual(result.snapshot?.originalIndex, 1)
    XCTAssertEqual(collection.recentlyClosed.last?.spaceID, spaceID)
  }

  func testRestoreReturnsTabToOriginalSpaceAndIndexWithNewID() {
    var collection = WorkspaceCollection(initialTab: tab("Main", "https://main.example"))
    let mainID = collection.selectedSpaceID
    let otherID = collection.createSpace(initialTab: tab("Other", "https://other.example"))!
    let restoredSource = tab("Source", "https://source.example")
    XCTAssertTrue(collection.appendTab(restoredSource, in: otherID, select: false))
    let originalIndex = collection.index(of: restoredSource.id, in: otherID)!
    _ = collection.close(restoredSource.id, reason: .userClosed)
    let snapshot = collection.popRecentlyClosed()!

    let restored = tab(snapshot.title, snapshot.url?.absoluteString)
    XCTAssertTrue(collection.restoreTab(restored, from: snapshot))
    XCTAssertEqual(collection.selectedSpaceID, otherID)
    XCTAssertEqual(collection.selectedTabID, restored.id)
    XCTAssertEqual(collection.index(of: restored.id, in: otherID), originalIndex)
    XCTAssertNotEqual(restored.id, restoredSource.id)
    XCTAssertNotEqual(collection.selectedSpaceID, mainID)
  }

  func testRenameTrimsWhitespace() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let id = collection.selectedSpaceID

    XCTAssertTrue(collection.renameSpace(id: id, name: "  Work  "))
    XCTAssertEqual(collection.space(withID: id)?.name, "Work")
  }

  func testEmptyRenameIsRejectedAndKeepsSafeName() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let id = collection.selectedSpaceID

    XCTAssertFalse(collection.renameSpace(id: id, name: " \n\t "))
    XCTAssertEqual(collection.space(withID: id)?.name, "Main")
  }

  func testUnknownSpaceAndTabOperationsAreSafe() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let unknown = UUID()
    XCTAssertNil(collection.space(withID: unknown))
    XCTAssertNil(collection.tab(withID: unknown))
    XCTAssertFalse(collection.selectSpace(id: unknown))
    XCTAssertFalse(collection.selectTab(id: unknown))
    XCTAssertFalse(collection.renameSpace(id: unknown, name: "Nope"))
    XCTAssertEqual(collection.close(unknown, reason: .userClosed).outcome, .unknownTab)
    XCTAssertTrue(collection.validateInvariants())
  }

  func testDuplicateTabCannotBelongToTwoSpaces() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let uniqueTab = tab("Unique", "https://unique.example")
    let first = collection.selectedSpaceID
    let second = collection.createSpace(initialTab: tab("Second"))!
    XCTAssertTrue(collection.appendTab(uniqueTab, in: first, select: false))
    XCTAssertFalse(collection.appendTab(uniqueTab, in: second, select: false))
    XCTAssertEqual(collection.spaceID(containing: uniqueTab.id), first)
    XCTAssertTrue(collection.validateInvariants())
  }

  func testSpaceAndTabOrderIsDeterministic() {
    var collection = WorkspaceCollection(initialTab: tab("Main"))
    let first = collection.selectedSpaceID
    let second = collection.createSpace(initialTab: tab("Second"))!
    XCTAssertTrue(collection.selectSpace(id: first))
    XCTAssertTrue(collection.appendTab(tab("Main 2"), in: first, select: false))
    XCTAssertTrue(collection.selectSpace(id: second))
    XCTAssertTrue(collection.appendTab(tab("Second 2"), in: second, select: false))

    XCTAssertEqual(collection.spaceIDs, [first, second])
    XCTAssertEqual(collection.tabs(in: first).map(\.title), ["Main", "Main 2"])
    XCTAssertEqual(collection.tabs(in: second).map(\.title), ["Second", "Second 2"])
    XCTAssertEqual(collection.allTabs.map(\.title), ["Main", "Main 2", "Second", "Second 2"])
  }

  func testRecentlyClosedStackIsBoundedAndLIFO() {
    var collection = WorkspaceCollection(initialTab: tab("Initial", "https://initial.example"))
    let spaceID = collection.selectedSpaceID
    for index in 0..<25 {
      let created = tab("T\(index)", "https://example.com/\(index)")
      XCTAssertTrue(collection.appendTab(created, in: spaceID, select: false))
      _ = collection.close(created.id, reason: .userClosed)
    }

    XCTAssertEqual(collection.recentlyClosed.count, WorkspaceCollection.recentlyClosedLimit)
    XCTAssertEqual(collection.popRecentlyClosed()?.title, "T24")
    XCTAssertEqual(collection.popRecentlyClosed()?.title, "T23")
  }

  func testThreeTiersReorderAndRestoreAcrossSpaceSwitch() throws {
    var collection = workspace(["A", "B", "C", "D"])
    let main = collection.selectedSpaceID
    let ids = collection.currentTabIDs
    XCTAssertTrue(collection.moveTab(ids[0], to: .global))
    XCTAssertTrue(collection.moveTab(ids[1], to: .global, before: ids[0]))
    XCTAssertTrue(collection.moveTab(ids[2], to: .space(main)))
    XCTAssertEqual(collection.globalPinnedTabs.map(\.title), ["B", "A"])
    XCTAssertEqual(collection.currentSpacePinnedTabs.map(\.title), ["C"])
    XCTAssertEqual(collection.currentTemporaryTabs.map(\.title), ["D"])

    let other = collection.createSpace(initialTab: tab("Other"))!
    XCTAssertEqual(collection.globalPinnedTabs.map(\.title), ["B", "A"])
    XCTAssertEqual(collection.currentSpacePinnedTabs.map(\.title), [])
    XCTAssertTrue(collection.selectTab(id: ids[0]))
    XCTAssertEqual(collection.selectedSpaceID, other)
    XCTAssertEqual(collection.selectedTabID, ids[0])
    let selectedRestore = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: collection))
    XCTAssertEqual(selectedRestore.selectedSpaceID, other)
    XCTAssertEqual(selectedRestore.selectedTabID, ids[0])
    XCTAssertTrue(collection.selectSpace(id: main))
    XCTAssertEqual(collection.selectedGlobalTabID, ids[0])
    XCTAssertEqual(collection.selectedTabID, ids[0])
    XCTAssertTrue(collection.selectTab(id: ids[2]))
    XCTAssertNil(collection.selectedGlobalTabID)
    XCTAssertEqual(collection.selectedTabID, ids[2])

    let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: collection))
    XCTAssertEqual(restored.globalPinnedTabs.map(\.title), ["B", "A"])
    XCTAssertEqual(restored.currentSpacePinnedTabs.map(\.title), ["C"])
    XCTAssertEqual(restored.currentTemporaryTabs.map(\.title), ["D"])
  }

  func testTopPinRemainsSelectedWhileSwitchingSpaces() {
    var collection = WorkspaceCollection(initialTab: tab("Top"))
    let first = collection.selectedSpaceID
    let top = collection.selectedTabID!
    XCTAssertTrue(collection.moveTab(top, to: .global))
    let secondTab = tab("Second")
    let second = collection.createSpace(initialTab: secondTab)!
    XCTAssertTrue(collection.selectTab(id: top))

    XCTAssertTrue(collection.selectSpace(id: first))
    XCTAssertEqual(collection.selectedGlobalTabID, top)
    XCTAssertEqual(collection.selectedTabID, top)
    XCTAssertTrue(collection.selectSpace(id: second))
    XCTAssertEqual(collection.selectedTabID, top)
    XCTAssertEqual(collection.space(withID: second)?.selectedTabID, secondTab.id)

    XCTAssertTrue(collection.selectTab(id: secondTab.id))
    XCTAssertNil(collection.selectedGlobalTabID)
    XCTAssertEqual(collection.selectedTabID, secondTab.id)
    XCTAssertTrue(collection.validateInvariants())
  }

  func testMovingLastTabToAnotherSpaceKeepsSourceUsable() throws {
    var collection = WorkspaceCollection(initialTab: tab("Only"))
    let source = collection.selectedSpaceID
    let onlyID = collection.selectedTabID!
    let destination = collection.createSpace(initialTab: tab("Other"))!
    XCTAssertTrue(collection.moveTab(onlyID, to: .space(destination)))
    XCTAssertEqual(collection.tabs(in: source).count, 1)
    XCTAssertEqual(collection.currentSpacePinnedTabs.map(\.title), ["Only"])
    XCTAssertTrue(collection.validateInvariants())
    XCTAssertNoThrow(try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: collection)))
  }

  func testGlobalPinLimitIsEnforced() {
    var collection = WorkspaceCollection(initialTab: tab("0"))
    let spaceID = collection.selectedSpaceID
    for index in 1...16 {
      XCTAssertTrue(collection.appendTab(tab("\(index)"), in: spaceID, select: false))
    }
    let ids = collection.currentTabIDs
    for id in ids.prefix(16) {
      XCTAssertTrue(collection.moveTab(id, to: .global))
    }
    XCTAssertFalse(collection.moveTab(ids[16], to: .global))
    XCTAssertEqual(collection.globalPinnedTabs.count, 16)
  }
}
