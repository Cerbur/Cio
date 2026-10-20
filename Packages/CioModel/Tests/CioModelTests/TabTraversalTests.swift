import CioModel
import XCTest

final class TabTraversalTests: XCTestCase {
  private func fixture() -> (WorkspaceCollection, [UUID]) {
    let tabs = ["A", "B", "C"].map { BrowserTab(title: $0) }
    var workspace = WorkspaceCollection(initialTab: tabs[0])
    for tab in tabs.dropFirst() {
      XCTAssertTrue(workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false))
    }
    return (workspace, tabs.map(\.id))
  }

  func testForwardAndReverseWrapWithoutChangingOrder() {
    var (workspace, ids) = fixture()
    let order = workspace.tabTraversalIDs
    XCTAssertEqual(workspace.adjacentTabID(forward: false), ids[2])
    for expected in [ids[1], ids[2], ids[0]] {
      XCTAssertEqual(workspace.adjacentTabID(forward: true), expected)
      XCTAssertTrue(workspace.selectTab(id: expected))
    }
    XCTAssertEqual(workspace.tabTraversalIDs, order)
    XCTAssertTrue(workspace.recentlyClosed.isEmpty)
  }

  func testTierOrderIncludesGlobalsOnceAndExcludesOtherSpaces() {
    var (workspace, ids) = fixture()
    let main = workspace.selectedSpaceID
    XCTAssertTrue(workspace.moveTab(ids[2], to: .global))
    XCTAssertTrue(workspace.moveTab(ids[1], to: .space(main)))
    XCTAssertEqual(workspace.tabTraversalIDs, [ids[2], ids[1], ids[0]])
    let other = BrowserTab(title: "Other Space")
    XCTAssertNotNil(workspace.createSpace(initialTab: other))
    XCTAssertEqual(workspace.tabTraversalIDs, [ids[2], other.id])
    XCTAssertEqual(workspace.adjacentTabID(forward: true), ids[2])
    XCTAssertTrue(workspace.selectTab(id: ids[2]))
    XCTAssertEqual(workspace.adjacentTabID(forward: true), other.id)
    XCTAssertTrue(workspace.selectSpace(id: main))
    XCTAssertEqual(workspace.tabTraversalIDs, [ids[2], ids[1], ids[0]])
  }

  func testClosedSpacePinRemainsReachableAndReopensOnSelection() {
    var (workspace, ids) = fixture()
    XCTAssertTrue(workspace.moveTab(ids[1], to: .space(workspace.selectedSpaceID)))
    _ = workspace.close(ids[1], reason: .userClosed)
    XCTAssertTrue(workspace.tab(withID: ids[1])!.isSpacePinClosed)
    XCTAssertEqual(workspace.adjacentTabID(forward: false), ids[1])
    XCTAssertTrue(workspace.selectTab(id: ids[1]))
    XCTAssertFalse(workspace.tab(withID: ids[1])!.isSpacePinClosed)
  }

  func testSplitPanesAreReachableAndKeepTheirGroup() throws {
    var (workspace, ids) = fixture()
    XCTAssertTrue(workspace.createSplit(with: ids[1], on: .right))
    XCTAssertTrue(workspace.selectTab(id: ids[0]))
    XCTAssertEqual(workspace.adjacentTabID(forward: true), ids[1])
    XCTAssertTrue(workspace.selectTab(id: ids[1]))
    XCTAssertEqual(workspace.activeSplit?.focusedTabID, ids[1])
    XCTAssertEqual(workspace.adjacentTabID(forward: true), ids[2])
    XCTAssertTrue(workspace.selectTab(id: ids[2]))
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(try XCTUnwrap(workspace.splitGroup(containing: ids[0])).tabIDs, [ids[0], ids[1]])
  }

  func testClosingTabsAreSkippedAndMissingSelectionUsesBoundary() {
    var (workspace, ids) = fixture()
    XCTAssertEqual(workspace.adjacentTabID(forward: true, excluding: [ids[1]]), ids[2])
    XCTAssertEqual(workspace.adjacentTabID(forward: false, excluding: [ids[2]]), ids[1])
    XCTAssertEqual(workspace.adjacentTabID(forward: true, excluding: [ids[0]]), ids[1])
    XCTAssertEqual(workspace.adjacentTabID(forward: false, excluding: [ids[0]]), ids[2])
    XCTAssertNil(workspace.adjacentTabID(forward: true, excluding: [ids[1], ids[2]]))
    XCTAssertNil(workspace.adjacentTabID(forward: true, excluding: Set(ids)))
    XCTAssertTrue(workspace.selectTab(id: ids[1]))
    XCTAssertEqual(workspace.adjacentTabID(forward: true, excluding: [ids[1]]), ids[2])
    XCTAssertEqual(workspace.adjacentTabID(forward: false, excluding: [ids[1]]), ids[0])
  }

  func testSingleAndEmptySpaceDoNotCycle() {
    let initial = BrowserTab(title: "Only")
    var workspace = WorkspaceCollection(initialTab: initial)
    XCTAssertNil(workspace.adjacentTabID(forward: true))
    XCTAssertNil(workspace.adjacentTabID(forward: false))
    _ = workspace.close(initial.id, reason: .userClosed)
    XCTAssertTrue(workspace.tabTraversalIDs.isEmpty)
    XCTAssertNil(workspace.adjacentTabID(forward: true))
  }
}
