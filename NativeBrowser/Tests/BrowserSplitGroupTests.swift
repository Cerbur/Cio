import XCTest

final class BrowserSplitGroupTests: XCTestCase {
  func testUngroupBadgeMakesLeftTabStableEvenWhenRightPaneIsSelected() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    XCTAssertEqual(workspace.selectedTabID, tabs[1].id)
    XCTAssertTrue(workspace.ungroupSplit(containing: tabs[1].id))
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(workspace.selectedTabID, tabs[0].id)
    XCTAssertEqual(workspace.selectedSpace?.stableTabStack.last, tabs[0].id)
    let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
    XCTAssertEqual(restored.selectedTabID, tabs[0].id)
    XCTAssertEqual(restored.selectedSpace?.stableTabStack.last, tabs[0].id)
    XCTAssertEqual(restored.allTabs.count, tabs.count)
  }

  func testGroupDragReordersBothMembersTogetherWithoutChangingItsLayout() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    _ = workspace.setSplitFraction(0.4)
    let group = try XCTUnwrap(workspace.activeSplit)
    XCTAssertTrue(workspace.moveSplitGroup(containing: tabs[0].id,
      to: .temporary(workspace.selectedSpaceID), before: tabs[4].id))
    XCTAssertEqual(workspace.currentTabIDs, [tabs[2].id, tabs[3].id, tabs[0].id, tabs[1].id, tabs[4].id])
    XCTAssertEqual(workspace.activeSplit, group)
    XCTAssertTrue(workspace.validateInvariants())
  }

  private func fixture() -> (WorkspaceCollection, [BrowserTab]) {
    let tabs = (0..<5).map { BrowserTab(title: "Page \($0)", url: URL(string: "https://example.com/\($0)")) }
    var workspace = WorkspaceCollection(initialTab: tabs[0])
    for tab in tabs.dropFirst() { _ = workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false) }
    return (workspace, tabs)
  }

  func testGroupsSurviveSelectingAnotherTabAndReturningToEitherMember() throws {
    var (workspace, tabs) = fixture()
    XCTAssertTrue(workspace.createSplit(with: tabs[1].id, on: .right))
    let group = try XCTUnwrap(workspace.activeSplit)
    XCTAssertEqual(group.tabIDs, [tabs[0].id, tabs[1].id])
    XCTAssertEqual(group.focusedTabID, tabs[1].id)
    _ = workspace.selectTab(id: tabs[4].id)
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(workspace.selectedSpace?.splitGroups.count, 1)
    _ = workspace.selectTab(id: tabs[0].id)
    XCTAssertEqual(workspace.activeSplit?.id, group.id)
    XCTAssertEqual(workspace.activeSplit?.focusedTabID, tabs[0].id)
  }

  func testMultipleGroupsInOneSpacePersistIndependently() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .left)
    _ = workspace.setSplitFraction(0.35)
    let first = try XCTUnwrap(workspace.activeSplit)
    _ = workspace.selectTab(id: tabs[2].id)
    _ = workspace.createSplit(with: tabs[3].id, on: .right)
    _ = workspace.setSplitFraction(0.65)
    let second = try XCTUnwrap(workspace.activeSplit)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(workspace.selectedSpace?.splitGroups, [first, second])
    let data = try JSONEncoder().encode(WorkspaceSessionSnapshot(workspace: workspace))
    let snapshot = try JSONDecoder().decode(WorkspaceSessionSnapshot.self, from: data)
    let restored = try WorkspaceCollection(restoring: snapshot)
    XCTAssertEqual(restored.selectedSpace?.splitGroups, [first, second])
    XCTAssertEqual(restored.activeSplit, second)
    XCTAssertEqual(restored.allTabIDs, workspace.allTabIDs)
    XCTAssertTrue(restored.validateInvariants())
  }

  func testGroupsRestoreAfterSwitchingSpaces() throws {
    var (workspace, tabs) = fixture()
    let main = workspace.selectedSpaceID
    _ = workspace.createSplit(with: tabs[1].id, on: .left)
    let group = workspace.activeSplit
    let other = try XCTUnwrap(workspace.createSpace(initialTab: BrowserTab(title: "Other")))
    XCTAssertNil(workspace.activeSplit)
    let restoredSnapshot = WorkspaceSessionSnapshot(workspace: workspace)
    var restored = try WorkspaceCollection(restoring: restoredSnapshot)
    XCTAssertEqual(restored.selectedSpaceID, other)
    _ = restored.selectSpace(id: main)
    XCTAssertEqual(restored.activeSplit, group)
  }

  func testReplacingAnActiveGroupReleasesOnlyItsFormerOtherMember() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    let identity = workspace.activeSplit?.id
    _ = workspace.createSplit(with: tabs[2].id, on: .left)
    XCTAssertEqual(workspace.activeSplit?.id, identity)
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [tabs[2].id, tabs[1].id])
    XCTAssertNil(workspace.splitGroup(containing: tabs[0].id))
    XCTAssertEqual(workspace.allTabs.count, tabs.count)
  }

  func testClosingOrMovingOneMemberDissolvesTheGroupWithoutLosingTheOtherTab() {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    _ = workspace.close(tabs[0].id, reason: .userClosed)
    XCTAssertTrue(workspace.selectedSpace!.splitGroups.isEmpty)
    XCTAssertNotNil(workspace.tab(withID: tabs[1].id))
    _ = workspace.createSplit(with: tabs[2].id, on: .left)
    _ = workspace.moveTab(tabs[2].id, to: .global)
    XCTAssertTrue(workspace.selectedSpace!.splitGroups.isEmpty)
    XCTAssertNotNil(workspace.tab(withID: tabs[1].id))
    XCTAssertTrue(workspace.validateInvariants())
  }

  func testUngroupAndSwapKeepBothTabsAndFocusedPane() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    _ = workspace.setSplitFraction(0.3)
    let identity = workspace.activeSplit?.id
    _ = workspace.swapSplitSides(containing: tabs[0].id)
    let swapped = try XCTUnwrap(workspace.activeSplit)
    XCTAssertEqual(swapped.id, identity)
    XCTAssertEqual(swapped.tabIDs, [tabs[1].id, tabs[0].id])
    XCTAssertEqual(swapped.fraction, 0.7, accuracy: 0.0001)
    XCTAssertEqual(swapped.focusedTabID, tabs[1].id)
    _ = workspace.endSplit(keeping: tabs[0].id)
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(workspace.allTabs.count, tabs.count)
  }

  func testCreatingFromASpacePinAndPinningWholeGroupKeepASingleTier() throws {
    var (workspace, tabs) = fixture()
    let spaceID = workspace.selectedSpaceID
    _ = workspace.moveTab(tabs[0].id, to: .space(spaceID))
    _ = workspace.createSplit(with: tabs[1].id, on: .left)
    let group = try XCTUnwrap(workspace.activeSplit)
    XCTAssertTrue(group.tabIDs.allSatisfy { workspace.selectedSpace!.pinnedTabIDs.contains($0) })
    _ = workspace.moveSplitGroup(containing: tabs[0].id, to: .temporary(spaceID))
    XCTAssertEqual(workspace.activeSplit, group)
    XCTAssertTrue(workspace.selectedSpace!.pinnedTabIDs.isEmpty)
    _ = workspace.moveSplitGroup(containing: tabs[0].id, to: .space(spaceID))
    XCTAssertEqual(workspace.activeSplit, group)
    XCTAssertTrue(workspace.validateInvariants())
  }

  func testMovingWholeGroupToAnotherSpacePreservesLayoutAndMembership() throws {
    var (workspace, tabs) = fixture()
    let main = workspace.selectedSpaceID
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    let group = try XCTUnwrap(workspace.activeSplit)
    let other = try XCTUnwrap(workspace.createSpace(initialTab: BrowserTab(), select: false))
    XCTAssertTrue(workspace.moveSplitGroup(containing: tabs[0].id, to: .temporary(other)))
    XCTAssertTrue(workspace.space(withID: main)!.splitGroups.isEmpty)
    XCTAssertEqual(workspace.space(withID: other)?.splitGroups, [group])
    XCTAssertEqual(workspace.selectedSpaceID, other)
    XCTAssertEqual(workspace.activeSplit, group)
    XCTAssertTrue(workspace.validateInvariants())
  }

  func testLegacySnapshotsWithoutGroupsRetainAllTabs() throws {
    let (workspace, _) = fixture()
    let data = try JSONEncoder().encode(WorkspaceSessionSnapshot(workspace: workspace))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var spaces = try XCTUnwrap(json["spaces"] as? [[String: Any]])
    for index in spaces.indices { spaces[index].removeValue(forKey: "splitGroups") }
    json["spaces"] = spaces
    let legacy = try JSONSerialization.data(withJSONObject: json)
    let snapshot = try JSONDecoder().decode(WorkspaceSessionSnapshot.self, from: legacy)
    let restored = try WorkspaceCollection(restoring: snapshot)
    XCTAssertEqual(restored.allTabIDs, workspace.allTabIDs)
    XCTAssertTrue(restored.selectedSpace!.splitGroups.isEmpty)
  }

  func testBrokenOrOverlappingGroupReferencesDoNotDiscardValidTabs() throws {
    let (workspace, tabs) = fixture()
    var space = try XCTUnwrap(WorkspaceSessionSnapshot(workspace: workspace).spaces.first)
    let valid = BrowserSplitLayout(leftTabID: tabs[0].id, rightTabID: tabs[1].id)
    space.splitGroups = [
      BrowserSplitLayout(leftTabID: tabs[0].id, rightTabID: UUID()),
      valid,
      BrowserSplitLayout(leftTabID: tabs[1].id, rightTabID: tabs[2].id),
      BrowserSplitLayout(leftTabID: tabs[3].id, rightTabID: tabs[3].id),
      BrowserSplitLayout(leftTabID: tabs[3].id, rightTabID: tabs[4].id, fraction: 2),
    ]
    let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(
      selectedSpaceID: workspace.selectedSpaceID, spaces: [space]))
    XCTAssertEqual(restored.selectedSpace?.splitGroups, [valid])
    XCTAssertEqual(restored.allTabIDs, workspace.allTabIDs)
    XCTAssertTrue(restored.validateInvariants())
  }

  func testMalformedGroupJSONIsIgnoredWhileTabsStillRestore() throws {
    let (workspace, _) = fixture()
    let data = try JSONEncoder().encode(WorkspaceSessionSnapshot(workspace: workspace))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var spaces = try XCTUnwrap(json["spaces"] as? [[String: Any]])
    spaces[0]["splitGroups"] = [["leftTabID": "not-a-uuid"]]
    json["spaces"] = spaces
    let snapshot = try JSONDecoder().decode(WorkspaceSessionSnapshot.self,
      from: JSONSerialization.data(withJSONObject: json))
    let restored = try WorkspaceCollection(restoring: snapshot)
    XCTAssertEqual(restored.allTabIDs, workspace.allTabIDs)
    XCTAssertTrue(restored.selectedSpace!.splitGroups.isEmpty)
  }

  func testFilePersistenceRetainsOrderFocusAndFraction() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .left)
    _ = workspace.setSplitFraction(0.4)
    _ = workspace.selectTab(id: tabs[0].id)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("split-restore-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(dataDirectory: directory, environment: [:], arguments: [])
    XCTAssertTrue(store.saveSnapshot(WorkspaceSessionSnapshot(workspace: workspace)))
    let restored = try WorkspaceCollection(restoring: XCTUnwrap(store.loadSnapshot()))
    XCTAssertEqual(restored.activeSplit, workspace.activeSplit)
    XCTAssertEqual(restored.selectedTabID, tabs[0].id)
    XCTAssertEqual(restored.activeSplit?.focusedTabID, tabs[0].id)
  }
}
