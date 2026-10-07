import CioModel
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

  func testSinglePageMiddleDropSelectsTheIncomingPageWithoutGrouping() throws {
    var (workspace, tabs) = fixture()
    XCTAssertTrue(workspace.createSplit(with: tabs[1].id, on: .middle))
    XCTAssertEqual(workspace.selectedTabID, tabs[1].id)
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(workspace.allTabIDs, tabs.map(\.id))
  }

  func testEveryDropSideAddsThirdPaneForEveryPinCombination() throws {
    for side in [BrowserSplitLayout.Side.left, .middle, .right] {
      for groupTier in 0...2 {
        for incomingTier in 0...2 {
          var (workspace, tabs) = fixture()
          let spaceID = workspace.selectedSpaceID
          let tiers: [WorkspaceCollection.TabTier] = [.temporary(spaceID), .space(spaceID), .global]
          _ = workspace.createSplit(with: tabs[1].id, on: .right)
          if groupTier != 0 { _ = workspace.moveSplitGroup(containing: tabs[0].id, to: tiers[groupTier]) }
          if incomingTier != 0 { _ = workspace.moveTab(tabs[2].id, to: tiers[incomingTier]) }
          let original = try XCTUnwrap(workspace.activeSplit)
          let count = workspace.allTabs.count
          let bounds = CGRect(x: 100, y: 20, width: 1200, height: 700)
          let x = side == .left ? bounds.minX + 1 : (side == .right ? bounds.maxX - 1 : original.paneFrames(in: bounds).dividers[0].midX)
          let target = original.dropTarget(at: x, in: bounds)
          XCTAssertEqual(target, .init(side: side))
          XCTAssertTrue(workspace.createSplit(with: tabs[2].id, at: target))
          let group = try XCTUnwrap(workspace.activeSplit)
          XCTAssertEqual(group.tabIDs.compactMap { workspace.tab(withID: $0)?.url },
                         side == .left ? [tabs[2].url, tabs[0].url, tabs[1].url]
                           : (side == .middle ? [tabs[0].url, tabs[2].url, tabs[1].url] : [tabs[0].url, tabs[1].url, tabs[2].url]))
          XCTAssertEqual(group.focusedTabID, side == .left ? group.leftTabID : (side == .middle ? group.middleTabID : group.rightTabID))
          XCTAssertEqual(group.fraction, 1.0 / 3)
          XCTAssertEqual(group.secondFraction, 2.0 / 3)
          XCTAssertEqual(workspace.allTabs.count, count + (groupTier == 0 ? 0 : 2) + (incomingTier == 0 ? 0 : 1))
          XCTAssertTrue(group.tabIDs.allSatisfy { workspace.tabIDs(in: .temporary(spaceID)).contains($0) })
          if groupTier != 0 { XCTAssertEqual(workspace.splitGroup(containing: tabs[0].id), original) }
          let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
          XCTAssertEqual(restored.activeSplit, group)
          XCTAssertTrue(restored.validateInvariants())
        }
      }
    }
  }

  func testPaneBodyDropReplacesPairForEveryPinCombination() throws {
    for side in [BrowserSplitLayout.Side.left, .right] {
      for groupTier in 0...2 {
        for incomingTier in 0...2 {
          var (workspace, tabs) = fixture()
          let spaceID = workspace.selectedSpaceID
          let tiers: [WorkspaceCollection.TabTier] = [.temporary(spaceID), .space(spaceID), .global]
          _ = workspace.createSplit(with: tabs[1].id, on: .right)
          _ = workspace.setSplitFraction(0.65)
          if groupTier != 0 { _ = workspace.moveSplitGroup(containing: tabs[0].id, to: tiers[groupTier]) }
          if incomingTier != 0 { _ = workspace.moveTab(tabs[2].id, to: tiers[incomingTier]) }
          let original = try XCTUnwrap(workspace.activeSplit)
          let count = workspace.allTabs.count
          let globals = workspace.globalPinnedTabIDs
          let pins = workspace.selectedSpace?.pinnedTabIDs
          let bounds = CGRect(x: 100, y: 20, width: 1200, height: 700)
          let index = side == .left ? 0 : 1
          let x = original.paneFrames(in: bounds).panes[index].midX
          let target = original.dropTarget(at: x, in: bounds)
          XCTAssertEqual(target, .init(side: side, replacesPane: true))
          let preview = original.placingPane(tabs[2].id, at: target)
          XCTAssertEqual(preview.tabIDs.count, 2)
          XCTAssertEqual(preview.fraction, original.fraction)
          XCTAssertTrue(workspace.createSplit(with: tabs[2].id, at: target))
          let group = try XCTUnwrap(workspace.activeSplit)
          XCTAssertEqual(group.tabIDs.compactMap { workspace.tab(withID: $0)?.url },
                         side == .left ? [tabs[2].url, tabs[1].url] : [tabs[0].url, tabs[2].url])
          XCTAssertEqual(group.tabIDs.count, 2)
          XCTAssertEqual(group.fraction, original.fraction)
          XCTAssertNil(group.secondFraction)
          XCTAssertEqual(group.focusedTabID, side == .left ? group.leftTabID : group.rightTabID)
          XCTAssertEqual(workspace.selectedTabID, group.focusedTabID)
          XCTAssertEqual(workspace.allTabs.count, count + (groupTier == 0 ? 0 : 1) + (incomingTier == 0 ? 0 : 1))
          XCTAssertEqual(workspace.globalPinnedTabIDs, globals)
          XCTAssertEqual(workspace.selectedSpace?.pinnedTabIDs, pins)
          if groupTier == 0 {
            XCTAssertEqual(group.id, original.id)
            XCTAssertNil(workspace.splitGroup(containing: original.tabIDs[index]))
            let order = workspace.tabIDs(in: .temporary(spaceID))
            let start = try XCTUnwrap(order.firstIndex(of: group.leftTabID))
            XCTAssertEqual(Array(order[start..<(start + 3)]), group.tabIDs + [original.tabIDs[index]])
          } else {
            XCTAssertEqual(workspace.splitGroup(containing: tabs[0].id), original)
          }
          XCTAssertTrue(workspace.validateInvariants())
          let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
          XCTAssertEqual(restored.activeSplit, group)
        }
      }
    }
  }

  func testDraggingPairIntoSinglePageMakesTripleInTheDropOrder() throws {
    for side in [BrowserSplitLayout.Side.left, .right] {
      for groupTier in 0...2 {
        for survivorTier in 0...2 {
          var (workspace, tabs) = fixture()
          let spaceID = workspace.selectedSpaceID
          let tiers: [WorkspaceCollection.TabTier] = [.temporary(spaceID), .space(spaceID), .global]
          _ = workspace.createSplit(with: tabs[1].id, on: .right)
          if groupTier != 0 { _ = workspace.moveSplitGroup(containing: tabs[0].id, to: tiers[groupTier]) }
          let original = workspace.activeSplit
          if survivorTier != 0 { _ = workspace.moveTab(tabs[2].id, to: tiers[survivorTier]) }
          _ = workspace.selectTab(id: tabs[2].id)
          XCTAssertTrue(workspace.canSplit(with: tabs[0].id))
          XCTAssertTrue(workspace.createSplit(with: tabs[0].id, on: side))
          let group = try XCTUnwrap(workspace.activeSplit)
          let expected = side == .left ? [tabs[0].url, tabs[1].url, tabs[2].url]
            : [tabs[2].url, tabs[0].url, tabs[1].url]
          XCTAssertEqual(group.tabIDs.compactMap { workspace.tab(withID: $0)?.url }, expected)
          if groupTier != 0 { XCTAssertEqual(workspace.splitGroup(containing: tabs[0].id), original) }
          XCTAssertTrue(group.tabIDs.allSatisfy { workspace.tabIDs(in: .temporary(spaceID)).contains($0) },
            "side=\(side) groupTier=\(groupTier) survivorTier=\(survivorTier) ids=\(group.tabIDs) temp=\(workspace.tabIDs(in: .temporary(spaceID)))")
          XCTAssertTrue(workspace.validateInvariants())
        }
      }
    }
  }

  func testPairMiddleDropIntoSinglePageReturnsToThePairWithoutMerging() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    let original = workspace.activeSplit
    _ = workspace.selectTab(id: tabs[2].id)
    XCTAssertTrue(workspace.createSplit(with: tabs[0].id, on: .middle))
    XCTAssertEqual(workspace.activeSplit?.tabIDs, original?.tabIDs)
    XCTAssertEqual(workspace.selectedSpace?.splitGroups.count, 1)
    XCTAssertNil(workspace.splitGroup(containing: tabs[2].id))
  }

  func testTripleReplacementSwapResizeAndWholeGroupMovement() throws {
    for side in [BrowserSplitLayout.Side.left, .middle, .right] {
      var (workspace, tabs) = fixture()
      _ = workspace.createSplit(with: tabs[1].id, on: .right)
      _ = workspace.createSplit(with: tabs[2].id, on: .middle)
      let original = try XCTUnwrap(workspace.activeSplit)
      let index = side == .left ? 0 : (side == .middle ? 1 : 2)
      var expected = original.tabIDs
      let displaced = expected[index]
      expected[index] = tabs[3].id
      XCTAssertTrue(workspace.createSplit(with: tabs[3].id, on: side))
      XCTAssertEqual(workspace.activeSplit?.tabIDs, expected)
      XCTAssertEqual(workspace.activeSplit?.id, original.id)
      XCTAssertNil(workspace.splitGroup(containing: displaced))
      XCTAssertEqual(workspace.currentTabIDs.prefix(4), expected + [displaced])
      XCTAssertTrue(workspace.setSplitFraction(0.25))
      XCTAssertTrue(workspace.setSplitFraction(0.7, divider: 1))
      XCTAssertTrue(workspace.swapSplitSides(containing: tabs[3].id))
      XCTAssertEqual(workspace.activeSplit?.tabIDs, Array(expected.reversed()))
      XCTAssertEqual(workspace.activeSplit!.fraction, 0.3, accuracy: 0.001)
      XCTAssertEqual(workspace.activeSplit!.secondFraction!, 0.75, accuracy: 0.001)
      XCTAssertTrue(workspace.moveSplitGroup(containing: tabs[3].id, to: .global))
      XCTAssertEqual(workspace.globalPinnedTabIDs, Array(expected.reversed()))
      let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
      XCTAssertEqual(restored.activeSplit, workspace.activeSplit)
      XCTAssertTrue(restored.validateInvariants())
    }
  }

  func testPaneExtractionPreservesSurvivorsOrderTierAndSelection() throws {
    for count in [2, 3] {
      for tierIndex in 0...2 {
        for paneIndex in 0..<count {
          var (workspace, tabs) = fixture()
          let spaceID = workspace.selectedSpaceID
          _ = workspace.createSplit(with: tabs[1].id, on: .right)
          if count == 3 { _ = workspace.createSplit(with: tabs[2].id, on: .middle) }
          let tiers: [WorkspaceCollection.TabTier] = [.temporary(spaceID), .space(spaceID), .global]
          if tierIndex != 0 { _ = workspace.moveSplitGroup(containing: tabs[0].id, to: tiers[tierIndex]) }
          let group = try XCTUnwrap(workspace.activeSplit)
          let removed = group.tabIDs[paneIndex]
          let remaining = group.tabIDs.filter { $0 != removed }
          _ = workspace.selectTab(id: removed)
          XCTAssertTrue(workspace.detachSplitPane(removed))
          XCTAssertEqual(workspace.selectedTabID, remaining[0])
          let order = workspace.tabIDs(in: tiers[tierIndex])
          let start = try XCTUnwrap(order.firstIndex(of: remaining[0]))
          XCTAssertEqual(Array(order[start..<(start + count)]), remaining + [removed])
          XCTAssertNil(workspace.splitGroup(containing: removed))
          if count == 3 {
            XCTAssertEqual(workspace.activeSplit?.id, group.id)
            XCTAssertEqual(workspace.activeSplit?.tabIDs, remaining)
          } else { XCTAssertNil(workspace.activeSplit) }
          XCTAssertEqual(workspace.allTabs.count, tabs.count)
          XCTAssertTrue(workspace.validateInvariants())
          let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
          XCTAssertEqual(restored.activeSplit, workspace.activeSplit)
          XCTAssertEqual(restored.selectedTabID, workspace.selectedTabID)
          XCTAssertEqual(restored.tabIDs(in: tiers[tierIndex]), order)
        }
      }
    }
  }

  func testMinimizeOtherPaneKeepsStablePageAndExpandSelectsExtractedPage() throws {
    for expand in [false, true] {
      var (workspace, tabs) = fixture()
      _ = workspace.createSplit(with: tabs[1].id, on: .right)
      _ = workspace.createSplit(with: tabs[2].id, on: .middle)
      _ = workspace.selectTab(id: tabs[0].id)
      XCTAssertTrue(workspace.detachSplitPane(tabs[2].id, selectDetached: expand))
      XCTAssertEqual(workspace.selectedTabID, expand ? tabs[2].id : tabs[0].id)
      XCTAssertEqual(workspace.selectedSpace?.stableTabStack.last, workspace.selectedTabID)
      XCTAssertEqual(workspace.splitGroup(containing: tabs[0].id)?.tabIDs, [tabs[0].id, tabs[1].id])
      XCTAssertEqual(workspace.currentTabIDs.prefix(3), [tabs[0].id, tabs[1].id, tabs[2].id])
    }
  }

  func testPaneDropMovesOnlyOnePageAndPreservesRemainingGroup() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    _ = workspace.createSplit(with: tabs[2].id, on: .middle)
    let groupID = workspace.activeSplit?.id
    XCTAssertTrue(workspace.moveSplitPane(tabs[2].id, to: .temporary(workspace.selectedSpaceID), before: tabs[4].id))
    XCTAssertEqual(workspace.currentTabIDs, [tabs[0].id, tabs[1].id, tabs[3].id, tabs[2].id, tabs[4].id])
    XCTAssertEqual(workspace.activeSplit?.id, groupID)
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [tabs[0].id, tabs[1].id])
    XCTAssertEqual(workspace.selectedTabID, tabs[0].id)
    XCTAssertTrue(workspace.validateInvariants())
  }

  func testInvalidPaneDropDoesNotPartiallyExtractPage() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    let before = workspace
    XCTAssertFalse(workspace.moveSplitPane(tabs[1].id, to: .temporary(UUID())))
    XCTAssertEqual(workspace, before)
    XCTAssertFalse(workspace.moveSplitPane(tabs[1].id, to: .temporary(workspace.selectedSpaceID), before: tabs[0].id))
    XCTAssertEqual(workspace, before)
    for _ in 0..<WorkspaceCollection.globalPinnedTabLimit {
      let tab = BrowserTab()
      _ = workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false)
      _ = workspace.moveTab(tab.id, to: .global)
    }
    let fullPins = workspace
    XCTAssertFalse(workspace.moveSplitPane(tabs[1].id, to: .global))
    XCTAssertEqual(workspace, fullPins)
  }

  func testPaneReorderPreservesIdentityFocusAndWidthsAndPersists() throws {
    for count in [2, 3] {
      for source in 0..<count {
        for destination in 0..<count {
          var (workspace, tabs) = fixture()
          _ = workspace.createSplit(with: tabs[1].id, on: .right)
          if count == 3 { _ = workspace.createSplit(with: tabs[2].id, on: .middle) }
          _ = workspace.setSplitFraction(count == 3 ? 0.3 : 0.4)
          let group = try XCTUnwrap(workspace.activeSplit)
          let id = group.tabIDs[source]
          var expected = group.tabIDs.filter { $0 != id }
          expected.insert(id, at: destination)
          XCTAssertTrue(workspace.reorderSplitPane(id, to: destination))
          XCTAssertEqual(workspace.activeSplit?.id, group.id)
          XCTAssertEqual(workspace.activeSplit?.tabIDs, expected)
          XCTAssertEqual(workspace.activeSplit?.fraction, group.fraction)
          XCTAssertEqual(workspace.activeSplit?.secondFraction, group.secondFraction)
          XCTAssertEqual(workspace.selectedTabID, group.focusedTabID)
          XCTAssertEqual(Array(workspace.currentTabIDs.prefix(count)), expected)
          let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
          XCTAssertEqual(restored.activeSplit, workspace.activeSplit)
          XCTAssertTrue(restored.validateInvariants())
        }
      }
    }
  }

  func testCloseExtractedTriplePaneKeepsOtherTwoPagesGrouped() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    _ = workspace.createSplit(with: tabs[2].id, on: .middle)
    XCTAssertTrue(workspace.detachSplitPane(tabs[2].id))
    _ = workspace.close(tabs[2].id, reason: .userClosed)
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [tabs[0].id, tabs[1].id])
    XCTAssertNil(workspace.tab(withID: tabs[2].id))
    XCTAssertEqual(workspace.allTabs.count, tabs.count - 1)
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

  func testLeftInsertionKeepsBothOriginalMembers() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    let identity = workspace.activeSplit?.id
    _ = workspace.createSplit(with: tabs[2].id, on: .left)
    XCTAssertEqual(workspace.activeSplit?.id, identity)
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [tabs[2].id, tabs[0].id, tabs[1].id])
    XCTAssertEqual(workspace.splitGroup(containing: tabs[0].id)?.id, identity)
    XCTAssertEqual(workspace.allTabs.count, tabs.count)
  }

  func testTripleTemporaryReplacementUsesDropSideAndPlacesDisplacedPageAfterGroup() throws {
    for focusedIndex in 0...1 {
      for side in [BrowserSplitLayout.Side.left, .right] {
        for incomingTier in 0...2 {
          for incomingBeforeGroup in [false, true] {
            var (workspace, tabs) = fixture()
            let spaceID = workspace.selectedSpaceID
            _ = workspace.createSplit(with: tabs[1].id, on: .right)
            _ = workspace.createSplit(with: tabs[3].id, on: .middle)
            _ = workspace.setSplitFraction(0.3)
            if incomingBeforeGroup {
              _ = workspace.moveSplitGroup(containing: tabs[0].id, to: .temporary(spaceID), before: tabs[4].id)
            }
            let incoming = tabs[2]
            let tiers: [WorkspaceCollection.TabTier] = [.temporary(spaceID), .space(spaceID), .global]
            if incomingTier != 0 { _ = workspace.moveTab(incoming.id, to: tiers[incomingTier]) }
            _ = workspace.selectTab(id: tabs[focusedIndex].id)
            let prior = try XCTUnwrap(workspace.activeSplit)
            let beforeOrder = workspace.tabIDs(in: .temporary(spaceID))
            let beforeRows = beforeOrder.filter { $0 != prior.rightTabID && $0 != prior.middleTabID && $0 != incoming.id }
            let globals = workspace.globalPinnedTabIDs
            let pins = workspace.selectedSpace!.pinnedTabIDs
            XCTAssertTrue(workspace.createSplit(with: incoming.id, on: side))
            let group = try XCTUnwrap(workspace.activeSplit)
            let displacedID = side == .left ? prior.leftTabID : prior.rightTabID
            let retainedID = side == .left ? prior.rightTabID : prior.leftTabID
            let incomingID = side == .left ? group.leftTabID : group.rightTabID
            XCTAssertEqual(side == .left ? group.rightTabID : group.leftTabID, retainedID)
            XCTAssertEqual(group.middleTabID, prior.middleTabID)
            XCTAssertEqual(workspace.tab(withID: incomingID)?.url, incoming.url)
            XCTAssertEqual(incomingID == incoming.id, incomingTier == 0)
            XCTAssertEqual(group.id, prior.id)
            XCTAssertEqual(group.fraction, prior.fraction)
            XCTAssertEqual(group.focusedTabID, incomingID)
            XCTAssertEqual(workspace.selectedTabID, incomingID)
            let expected = beforeRows.flatMap { $0 == prior.leftTabID ? group.tabIDs + [displacedID] : [$0] }
            XCTAssertEqual(workspace.tabIDs(in: .temporary(spaceID)), expected)
            XCTAssertNil(workspace.splitGroup(containing: displacedID))
            XCTAssertEqual(workspace.globalPinnedTabIDs, globals)
            XCTAssertEqual(workspace.selectedSpace?.pinnedTabIDs, pins)
            XCTAssertEqual(workspace.allTabs.count, tabs.count + (incomingTier == 0 ? 0 : 1))
            XCTAssertTrue(workspace.validateInvariants())
            let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
            XCTAssertEqual(restored.activeSplit, group)
            XCTAssertEqual(restored.tabIDs(in: .temporary(spaceID)), expected)
          }
        }
      }
    }
  }

  func testTriplePinnedReplacementCreatesNewTemporaryGroupAtFrontAndPreservesOriginal() throws {
    for global in [false, true] {
      for focusedIndex in 0...1 {
        for side in [BrowserSplitLayout.Side.left, .right] {
          for incomingTier in 0...2 {
            var (workspace, tabs) = fixture()
            let owner = workspace.selectedSpaceID
            _ = workspace.createSplit(with: tabs[1].id, on: .right)
            _ = workspace.createSplit(with: tabs[3].id, on: .middle)
            _ = workspace.setSplitFraction(0.65)
            _ = workspace.moveSplitGroup(containing: tabs[0].id, to: global ? .global : .space(owner))
            if global {
              _ = workspace.createSpace(initialTab: BrowserTab(title: "Other"))
              _ = workspace.moveTab(tabs[2].id, to: .temporary(workspace.selectedSpaceID))
            }
            let spaceID = workspace.selectedSpaceID
            let tiers: [WorkspaceCollection.TabTier] = [.temporary(spaceID), .space(spaceID), .global]
            if incomingTier != 0 { _ = workspace.moveTab(tabs[2].id, to: tiers[incomingTier]) }
            _ = workspace.selectTab(id: tabs[focusedIndex].id)
            let original = try XCTUnwrap(workspace.activeSplit)
            let temporary = workspace.tabIDs(in: .temporary(spaceID))
            let count = workspace.allTabs.count
            let globals = workspace.globalPinnedTabIDs
            let pins = workspace.space(withID: owner)!.pinnedTabIDs
            XCTAssertTrue(workspace.createSplit(with: tabs[2].id, on: side))
            let group = try XCTUnwrap(workspace.activeSplit)
            XCTAssertNotEqual(group.id, original.id)
            XCTAssertEqual(group.fraction, original.fraction)
            let survivorID = side == .left ? group.rightTabID : group.leftTabID
            let originalSurvivor = side == .left ? original.rightTabID : original.leftTabID
            XCTAssertNotEqual(survivorID, originalSurvivor)
            XCTAssertEqual(workspace.tab(withID: survivorID)?.url, workspace.tab(withID: originalSurvivor)?.url)
            let incomingID = side == .left ? group.leftTabID : group.rightTabID
            XCTAssertEqual(workspace.tab(withID: incomingID)?.url, tabs[2].url)
            XCTAssertEqual(workspace.tabIDs(in: .temporary(spaceID)), group.tabIDs + temporary.filter { $0 != incomingID })
            XCTAssertEqual(workspace.splitGroup(containing: tabs[0].id), original)
            XCTAssertEqual(workspace.globalPinnedTabIDs, globals)
            XCTAssertEqual(workspace.space(withID: owner)?.pinnedTabIDs, pins)
            XCTAssertEqual(workspace.allTabs.count, count + 2 + (incomingTier == 0 ? 0 : 1))
            XCTAssertTrue(workspace.validateInvariants())
            let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
            XCTAssertEqual(restored.activeSplit, group)
            XCTAssertEqual(restored.splitGroup(containing: tabs[0].id), original)
          }
        }
      }
    }
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

  func testPinnedSplitCombinationsPreservePinsAndReuseTemporaryPosition() throws {
    for selectedTier in 0...2 {
      for incomingTier in 0...2 where selectedTier != 0 || incomingTier != 0 {
        for side in [BrowserSplitLayout.Side.left, .right] {
          var (workspace, tabs) = fixture()
          let spaceID = workspace.selectedSpaceID
          let tiers: [WorkspaceCollection.TabTier] = [.temporary(spaceID), .space(spaceID), .global]
          if selectedTier != 0 { _ = workspace.moveTab(tabs[0].id, to: tiers[selectedTier]) }
          if incomingTier != 0 { _ = workspace.moveTab(tabs[1].id, to: tiers[incomingTier]) }
          _ = workspace.selectTab(id: tabs[0].id)
          let globals = workspace.globalPinnedTabIDs
          let pins = workspace.selectedSpace!.pinnedTabIDs
          let temporary = workspace.tabIDs(in: .temporary(spaceID))
          let anchor = selectedTier == 0 ? tabs[0].id : (incomingTier == 0 ? tabs[1].id : nil)
          XCTAssertTrue(workspace.canSplit(with: tabs[1].id))
          XCTAssertTrue(workspace.createSplit(with: tabs[1].id, on: side))
          let group = try XCTUnwrap(workspace.activeSplit)
          let selectedMember = side == .left ? group.rightTabID : group.leftTabID
          let incomingMember = side == .left ? group.leftTabID : group.rightTabID
          XCTAssertEqual(workspace.tab(withID: selectedMember)?.url, tabs[0].url)
          XCTAssertEqual(workspace.tab(withID: incomingMember)?.url, tabs[1].url)
          XCTAssertEqual(selectedMember == tabs[0].id, selectedTier == 0)
          XCTAssertEqual(incomingMember == tabs[1].id, incomingTier == 0)
          XCTAssertEqual(workspace.globalPinnedTabIDs, globals)
          XCTAssertEqual(workspace.selectedSpace?.pinnedTabIDs, pins)
          for id in globals + pins { XCTAssertNil(workspace.splitGroup(containing: id)) }
          XCTAssertEqual(workspace.allTabs.count, tabs.count + (selectedTier == 0 ? 0 : 1) + (incomingTier == 0 ? 0 : 1))
          let combinedOrder = workspace.tabIDs(in: .temporary(spaceID)).filter { $0 != group.rightTabID }
          let expectedOrder = anchor.map { anchor in temporary.map { $0 == anchor ? group.leftTabID : $0 } }
            ?? ([group.leftTabID] + temporary)
          XCTAssertEqual(combinedOrder, expectedOrder)
          XCTAssertTrue(workspace.validateInvariants())
          let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
          XCTAssertEqual(restored.activeSplit, group)
        }
      }
    }
  }

  func testSpacePinnedAndTemporaryGroupsCanMoveToTopPinsAndRestoreAcrossSpaces() throws {
    for pinnedInSpace in [false, true] {
      var (workspace, tabs) = fixture()
      _ = workspace.createSplit(with: tabs[1].id, on: .right)
      _ = workspace.setSplitFraction(0.35)
      if pinnedInSpace { _ = workspace.moveSplitGroup(containing: tabs[0].id, to: .space(workspace.selectedSpaceID)) }
      let group = try XCTUnwrap(workspace.activeSplit)
      XCTAssertTrue(workspace.moveSplitGroup(containing: tabs[1].id, to: .global))
      XCTAssertEqual(workspace.globalPinnedTabIDs, group.tabIDs)
      XCTAssertEqual(workspace.activeSplit, group)
      let other = try XCTUnwrap(workspace.createSpace(initialTab: BrowserTab(), select: false))
      _ = workspace.selectSpace(id: other)
      XCTAssertEqual(workspace.activeSplit, group)
      XCTAssertTrue(workspace.setSplitFraction(0.6))
      let updated = workspace.activeSplit
      var restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
      XCTAssertEqual(restored.activeSplit, updated)
      XCTAssertEqual(restored.selectedSpaceID, other)
      XCTAssertTrue(restored.moveSplitGroup(containing: tabs[0].id, to: .temporary(other)))
      XCTAssertEqual(restored.activeSplit, updated)
      XCTAssertTrue(restored.globalPinnedTabIDs.isEmpty)
      XCTAssertTrue(restored.validateInvariants())
    }
  }

  func testTopPinCapacityRejectsWholeGroupWithoutPartialMutation() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .left)
    for _ in 0..<(WorkspaceCollection.globalPinnedTabLimit - 1) {
      let tab = BrowserTab()
      _ = workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false)
      _ = workspace.moveTab(tab.id, to: .global)
    }
    let before = workspace
    XCTAssertFalse(workspace.moveSplitGroup(containing: tabs[0].id, to: .global))
    XCTAssertEqual(workspace, before)
  }

  func testSplittingSelectedPinnedGroupPreservesTheOriginalGroup() throws {
    for global in [false, true] {
      var (workspace, tabs) = fixture()
      _ = workspace.createSplit(with: tabs[1].id, on: .right)
      _ = workspace.moveSplitGroup(containing: tabs[0].id,
        to: global ? .global : .space(workspace.selectedSpaceID))
      let original = try XCTUnwrap(workspace.activeSplit)
      XCTAssertTrue(workspace.createSplit(with: tabs[2].id, on: .left))
      XCTAssertEqual(workspace.splitGroup(containing: tabs[0].id), original)
      XCTAssertNotEqual(workspace.activeSplit?.id, original.id)
      XCTAssertTrue(workspace.activeSplit!.contains(tabs[2].id))
      XCTAssertEqual(workspace.allTabs.count, tabs.count + 2)
      XCTAssertEqual(workspace.activeSplit?.tabIDs.count, 3)
      XCTAssertTrue(workspace.validateInvariants())
    }
  }

  func testTopPinnedGroupCanReorderAndUngroupWhileAnotherSpaceIsSelected() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.createSplit(with: tabs[1].id, on: .right)
    _ = workspace.moveSplitGroup(containing: tabs[0].id, to: .global)
    _ = workspace.moveTab(tabs[2].id, to: .global)
    let group = workspace.activeSplit
    XCTAssertTrue(workspace.moveSplitGroup(containing: tabs[0].id, to: .global))
    XCTAssertEqual(workspace.globalPinnedTabIDs, [tabs[2].id, tabs[0].id, tabs[1].id])
    XCTAssertTrue(workspace.moveSplitGroup(containing: tabs[1].id, to: .global, before: tabs[2].id))
    XCTAssertEqual(workspace.globalPinnedTabIDs, [tabs[0].id, tabs[1].id, tabs[2].id])
    XCTAssertEqual(workspace.activeSplit, group)
    let other = try XCTUnwrap(workspace.createSpace(initialTab: BrowserTab(), select: false))
    _ = workspace.selectSpace(id: other)
    XCTAssertTrue(workspace.ungroupSplit(containing: tabs[1].id))
    XCTAssertEqual(workspace.selectedSpaceID, other)
    XCTAssertEqual(workspace.selectedTabID, tabs[0].id)
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(workspace.globalPinnedTabIDs, [tabs[0].id, tabs[1].id, tabs[2].id])
    XCTAssertTrue(workspace.validateInvariants())
  }

  func testTopPinFromAnotherSpaceCanSplitWithCurrentSpacePin() throws {
    var (workspace, tabs) = fixture()
    _ = workspace.moveTab(tabs[0].id, to: .global)
    let otherTab = BrowserTab(title: "Other", url: URL(string: "https://example.com/other"))
    let other = try XCTUnwrap(workspace.createSpace(initialTab: otherTab))
    _ = workspace.moveTab(otherTab.id, to: .space(other))
    XCTAssertTrue(workspace.createSplit(with: tabs[0].id, on: .right))
    XCTAssertEqual(workspace.selectedSpaceID, other)
    XCTAssertEqual(workspace.globalPinnedTabIDs, [tabs[0].id])
    XCTAssertEqual(workspace.selectedSpace?.pinnedTabIDs, [otherTab.id])
    XCTAssertEqual(workspace.tabIDs(in: .temporary(other)), workspace.activeSplit?.tabIDs)
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
