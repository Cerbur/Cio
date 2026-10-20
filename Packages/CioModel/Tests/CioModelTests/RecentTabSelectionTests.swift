import CioModel
import XCTest

final class RecentTabSelectionTests: XCTestCase {
  private func fixture() -> (WorkspaceCollection, [BrowserTab]) {
    let tabs = (0..<7).map { index in
      BrowserTab(title: "Page \(index)", url: URL(string: "https://example.com/\(index)"),
                 lastActivatedAt: Date(timeIntervalSince1970: Double(index)))
    }
    var workspace = WorkspaceCollection(initialTab: tabs[0])
    for tab in tabs.dropFirst() {
      XCTAssertTrue(workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false))
    }
    return (workspace, tabs)
  }

  func testCurrentPlusFourMostRecentRatherThanSidebarNeighbors() {
    let (workspace, tabs) = fixture()
    XCTAssertEqual(workspace.recentTabIDs(), [0, 6, 5, 4, 3].map { tabs[$0].id })
  }

  func testSplitCountsOnceBeforeFiveCandidateLimitAndRestoresFocusedPane() throws {
    var (workspace, tabs) = fixture()
    XCTAssertTrue(workspace.selectTab(id: tabs[6].id))
    XCTAssertTrue(workspace.createSplit(with: tabs[5].id, on: .right))
    let group = try XCTUnwrap(workspace.activeSplit)
    let focused = try XCTUnwrap(workspace.selectedTabID)
    XCTAssertTrue(workspace.selectTab(id: tabs[0].id))
    let ids = workspace.recentTabIDs()
    XCTAssertEqual(ids.count, 5, "Two panes must leave four other candidate slots")
    XCTAssertEqual(ids.first, tabs[0].id)
    XCTAssertEqual(ids[1], focused)
    XCTAssertEqual(ids.filter { group.contains($0) }.count, 1)
    let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
    XCTAssertEqual(restored.recentTabIDs(), ids)
  }

  func testThreePaneWorkspaceHasOnlyOneSwitchingCandidate() throws {
    let tabs = (0..<3).map { BrowserTab(title: "Pane \($0)") }
    var workspace = WorkspaceCollection(initialTab: tabs[0])
    for tab in tabs.dropFirst() {
      XCTAssertTrue(workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false))
      XCTAssertTrue(workspace.createSplit(with: tab.id, on: .right))
    }
    XCTAssertEqual(workspace.activeSplit?.tabIDs.count, 3)
    XCTAssertEqual(workspace.recentTabIDs(), [try XCTUnwrap(workspace.selectedTabID)])
    let selected = try XCTUnwrap(workspace.selectedTabID)
    let remaining = workspace.recentTabIDs(excluding: [selected])
    XCTAssertEqual(remaining.count, 1)
    XCTAssertNotEqual(remaining.first, selected)
  }

  func testCandidatesSpanSpacesAndIncludeGlobalPinOnce() {
    var (workspace, tabs) = fixture()
    XCTAssertTrue(workspace.moveTab(tabs[6].id, to: .global))
    let other = BrowserTab(title: "Other", lastActivatedAt: Date(timeIntervalSince1970: 20))
    XCTAssertNotNil(workspace.createSpace(initialTab: other, select: false))
    XCTAssertEqual(workspace.recentTabIDs(), [tabs[0].id, other.id, tabs[6].id, tabs[5].id, tabs[4].id])
    XCTAssertEqual(workspace.recentTabIDs().filter { $0 == tabs[6].id }.count, 1)
  }

  func testClosingTabsAndClosedPinBookmarksDoNotEnterCandidates() {
    var (workspace, tabs) = fixture()
    XCTAssertTrue(workspace.moveTab(tabs[6].id, to: .space(workspace.selectedSpaceID)))
    _ = workspace.close(tabs[6].id, reason: .userClosed)
    XCTAssertEqual(workspace.recentTabIDs(excluding: [tabs[5].id]), [0, 4, 3, 2, 1].map { tabs[$0].id })
  }

  func testTiesAreStableAndSurviveRestore() throws {
    let first = BrowserTab(title: "A", lastActivatedAt: .distantPast)
    let second = BrowserTab(title: "B", lastActivatedAt: .distantPast)
    var workspace = WorkspaceCollection(initialTab: first)
    XCTAssertTrue(workspace.appendTab(second, in: workspace.selectedSpaceID, select: false))
    let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
    XCTAssertEqual(restored.recentTabIDs(), [first.id, second.id])
  }

  func testHighlightingFreezesOrderAndLeavesWorkspaceUnchanged() {
    let (workspace, tabs) = fixture()
    let before = workspace
    let ids = workspace.recentTabIDs()
    var selection = RecentTabSelection(candidateIDs: ids, currentID: tabs[0].id, forward: true)
    XCTAssertEqual(selection.selectedID, tabs[6].id)
    selection.advance(forward: true)
    XCTAssertEqual(selection.selectedID, tabs[5].id)
    selection.advance(forward: false)
    XCTAssertEqual(selection.selectedID, tabs[6].id)
    XCTAssertEqual(selection.candidateIDs, ids)
    XCTAssertEqual(workspace, before, "Preview/cancel must not activate tabs or update MRU timestamps")
  }

  func testReverseWrapAndForwardWrap() {
    let ids = (0..<5).map { _ in UUID() }
    var selection = RecentTabSelection(candidateIDs: ids, currentID: ids[0], forward: false)
    XCTAssertEqual(selection.selectedID, ids[4])
    selection.advance(forward: true)
    XCTAssertEqual(selection.selectedID, ids[0])
    selection.advance(forward: false)
    XCTAssertEqual(selection.selectedID, ids[4])
  }

  func testASecondFlightReturnsToThePreviousTab() throws {
    var (workspace, _) = fixture()
    let original = workspace.selectedTabID
    let selection = RecentTabSelection(candidateIDs: workspace.recentTabIDs(), currentID: original, forward: true)
    XCTAssertTrue(workspace.selectTab(id: try XCTUnwrap(selection.selectedID)))
    let next = RecentTabSelection(candidateIDs: workspace.recentTabIDs(), currentID: workspace.selectedTabID, forward: true)
    XCTAssertEqual(next.selectedID, original)
  }

  func testCandidateRemovalPreservesHighlightOrSelectsAdjacentWithoutReordering() {
    let ids = (0..<5).map { _ in UUID() }
    var selection = RecentTabSelection(candidateIDs: ids, currentID: ids[0], forward: true)
    selection.retainAvailable(Set(ids.dropLast()))
    XCTAssertEqual(selection.selectedID, ids[1])
    selection.retainAvailable([ids[0], ids[2], ids[3]])
    XCTAssertEqual(selection.candidateIDs, [ids[0], ids[2], ids[3]])
    XCTAssertEqual(selection.selectedID, ids[2])
    selection.retainAvailable([])
    XCTAssertNil(selection.selectedID)
  }

  func testLimitDeduplicationClickAndEmptyState() {
    let ids = (0..<7).map { _ in UUID() }
    var selection = RecentTabSelection(candidateIDs: [ids[0]] + ids, currentID: ids[0], forward: true)
    XCTAssertEqual(selection.candidateIDs, Array(ids.prefix(5)))
    selection.select(ids[4])
    XCTAssertEqual(selection.selectedID, ids[4])
    selection.select(ids[6])
    XCTAssertEqual(selection.selectedID, ids[4])
    var empty = RecentTabSelection(candidateIDs: [], currentID: nil, forward: true)
    empty.advance(forward: false)
    XCTAssertNil(empty.selectedID)
    XCTAssertEqual(RecentTabSelection(candidateIDs: ids, currentID: nil, forward: true).selectedID, ids[0])
    XCTAssertEqual(RecentTabSelection(candidateIDs: ids, currentID: nil, forward: false).selectedID, ids[4])
  }
}
