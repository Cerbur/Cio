@testable import CioUI
import CioModel
import XCTest

final class SpaceTabPanelRowTests: XCTestCase {
  func testCommittingDraggedTabIntoGroupDoesNotHideExistingMembers() throws {
    let space = UUID(), existing = UUID(), incoming = UUID(), other = UUID()
    let source = Set([incoming])
    let before = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [],
      temporaryIDs: [existing, incoming, other], groups: [], liftedID: incoming, liftedIDs: source)
    let group = BrowserSplitLayout(leftTabID: incoming, rightTabID: existing)
    let committed = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [],
      temporaryIDs: [incoming, existing, other], groups: [group], liftedID: incoming, liftedIDs: source)
    let landed = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [],
      temporaryIDs: [incoming, existing, other], groups: [group], liftedIDs: [])
    func controls(_ rows: [SpaceTabPanelRow]) -> Set<SidebarTabPanelItem.ID> {
      Set(SidebarTabPanelItem.make(rows).filter { $0.tabID != nil }.map(\.id))
    }
    XCTAssertEqual(controls(before), controls(committed))
    XCTAssertTrue(controls(committed).contains(.tab(existing)))
    XCTAssertTrue(controls(committed).isSubset(of: controls(landed)))
    XCTAssertEqual(controls(landed).count, 3)
  }

  func testFlatControlsSurviveGroupingUngroupingAndCrossingDivider() throws {
    let space = UUID(), left = UUID(), right = UUID(), other = UUID()
    let ids = [left, right, other]
    let group = BrowserSplitLayout(leftTabID: left, rightTabID: right)
    func rows(_ groups: [BrowserSplitLayout], pinned: Bool = false) -> [SpaceTabPanelRow] {
      SpaceTabPanelRow.make(spaceID: space, pinnedIDs: pinned ? ids : [],
        temporaryIDs: pinned ? [] : ids, groups: groups)
    }
    func controlIDs(_ rows: [SpaceTabPanelRow]) -> [SidebarTabPanelItem.ID] {
      SidebarTabPanelItem.make(rows).filter { $0.tabID != nil }.map(\.id)
    }
    let single = rows([]), combined = rows([group]), pinned = rows([group], pinned: true)
    XCTAssertEqual(controlIDs(single), controlIDs(combined))
    XCTAssertEqual(controlIDs(single), controlIDs(pinned))
    XCTAssertEqual(controlIDs(combined), controlIDs(rows([])))
    let before = SidebarTabPanelLayout(rows: single).frames(width: 158)
    let after = SidebarTabPanelLayout(rows: combined).frames(width: 158)
    let a = try XCTUnwrap(after[.tab(left)]), b = try XCTUnwrap(after[.tab(right)])
    XCTAssertEqual(a.minY, b.minY)
    XCTAssertEqual(a.width, b.width)
    XCTAssertEqual(b.minX - a.maxX, BrowserLayout.sidebarSplitMemberSpacing)
    XCTAssertLessThan(a.width, try XCTUnwrap(before[.tab(left)]).width)
    XCTAssertEqual(a.height, BrowserLayout.sidebarTabRowHeight)
    XCTAssertEqual(Set(SidebarTabPanelItem.make(combined).map(\.id)).count,
      SidebarTabPanelItem.make(combined).count)
  }

  func testSplitSwapMovesTheSameControlsBetweenTheirPreviousSlots() throws {
    for count in [2, 3] {
      for columns in [1, 2, 3, 4] {
        let space = UUID(), left = UUID(), right = UUID(), middle = UUID()
        let group = BrowserSplitLayout(leftTabID: left, rightTabID: right,
          middleTabID: count == 3 ? middle : nil)
        var reversed = group
        reversed.leftTabID = right
        reversed.rightTabID = left
        func layout(_ group: BrowserSplitLayout) -> SidebarTabPanelLayout {
          let rows = SpaceTabPanelRow.makeTabs(group.tabIDs, spaceID: space, tier: .global, groups: [group])
          return SidebarTabPanelLayout(rows: rows, columns: columns)
        }
        let before = layout(group), after = layout(reversed)
        XCTAssertEqual(SidebarTabPanelItem.make(before.rows).filter { $0.tabID != nil }.map(\.id),
          SidebarTabPanelItem.make(after.rows).filter { $0.tabID != nil }.map(\.id))
        XCTAssertNotEqual(before.destinations, after.destinations)
        let a = before.frames(width: 400), b = after.frames(width: 400)
        XCTAssertEqual(a[.tab(left)], b[.tab(right)])
        XCTAssertEqual(a[.tab(right)], b[.tab(left)])
        if count == 3 { XCTAssertEqual(a[.tab(middle)], b[.tab(middle)]) }
        var focused = reversed
        focused.focusedTabID = left
        // Page focus updates do not restart movement to unchanged destinations.
        XCTAssertEqual(after.destinations, layout(focused).destinations)
      }
    }
  }

  func testCollapseReservationKeepsEveryNativeTabControlAtMidpointAndLanding() throws {
    let space = UUID(), left = UUID(), right = UUID()
    let group = BrowserSplitLayout(leftTabID: left, rightTabID: right)
    let reservation = SpaceTabPanelRow.PaneCollapse(tabID: left, tier: .temporary(space), group: group)
    func layout(_ groups: [BrowserSplitLayout], collapse: SpaceTabPanelRow.PaneCollapse?) -> SidebarTabPanelLayout {
      SidebarTabPanelLayout(rows: SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [],
        temporaryIDs: [right, left], groups: groups, paneCollapse: collapse))
    }
    let start = layout([group], collapse: reservation)
    let midpoint = layout([], collapse: reservation)
    let end = layout([], collapse: nil)
    func controls(_ layout: SidebarTabPanelLayout) -> [SidebarTabPanelItem.ID] {
      SidebarTabPanelItem.make(layout.rows).filter { $0.tabID != nil }.map(\.id)
    }
    XCTAssertEqual(controls(start), controls(midpoint))
    XCTAssertEqual(controls(midpoint), controls(end))
    XCTAssertEqual(start.frames(width: 158)[.tab(right)], end.frames(width: 158)[.tab(right)])
    XCTAssertEqual(start.frames(width: 158)[.tab(left)], end.frames(width: 158)[.tab(left)])
  }

  func testPaneCollapseReservesFinalSlotBeforeMidpointAndKeepsItThroughLanding() throws {
    for count in [2, 3] {
      for tierIndex in 0...2 {
        for paneIndex in 0..<count {
          let tabs = (0..<5).map { BrowserTab(title: "Tab \($0)") }
          var workspace = WorkspaceCollection(initialTab: tabs[0])
          for (index, tab) in tabs.dropFirst().enumerated() {
            _ = workspace.insertTab(tab, in: workspace.selectedSpaceID, at: index + 1, select: false)
          }
          let space = workspace.selectedSpaceID
          XCTAssertTrue(workspace.createSplit(with: tabs[1].id, on: .right))
          if count == 3 { XCTAssertTrue(workspace.createSplit(with: tabs[2].id, on: .middle)) }
          let tier: WorkspaceCollection.TabTier = [.temporary(space), .space(space), .global][tierIndex]
          if tierIndex != 0 { XCTAssertTrue(workspace.moveSplitGroup(containing: tabs[0].id, to: tier)) }
          let group = try XCTUnwrap(workspace.activeSplit)
          let detached = group.tabIDs[paneIndex]
          let reservation = SpaceTabPanelRow.PaneCollapse(tabID: detached, tier: tier, group: group)
          func rows(_ collapse: SpaceTabPanelRow.PaneCollapse?) -> [SpaceTabPanelRow] {
            if tier == .global {
              return SpaceTabPanelRow.makeTabs(workspace.tabIDs(in: tier), spaceID: space, tier: tier,
                groups: workspace.selectedSpace!.splitGroups, paneCollapse: collapse)
            }
            return SpaceTabPanelRow.make(spaceID: space,
              pinnedIDs: workspace.tabIDs(in: .space(space)), temporaryIDs: workspace.tabIDs(in: .temporary(space)),
              groups: workspace.selectedSpace!.splitGroups, paneCollapse: collapse)
          }
          let before = rows(nil)
          let workspaceBeforeReservation = workspace
          let reserved = rows(reservation)
          XCTAssertEqual(workspace, workspaceBeforeReservation)
          XCTAssertEqual(reserved.count, before.count + 1)
          let destination = try XCTUnwrap(reserved.firstIndex { $0.id == .tab(detached) })
          XCTAssertEqual(reserved[destination - 1].id, .group(group.id))
          XCTAssertEqual(reserved[destination - 1].splitGroup, group)
          XCTAssertEqual(Set(reserved.map(\.id)).count, reserved.count)
          XCTAssertEqual(Set(reserved.flatMap(\.tabIDs)), Set(before.flatMap(\.tabIDs)))
          XCTAssertEqual(reserved.flatMap(\.tabIDs).count, before.flatMap(\.tabIDs).count)

          XCTAssertTrue(workspace.detachSplitPane(detached))
          let midpoint = rows(reservation)
          // No structural change at the midpoint: lower rows keep their exact
          // indices, and the already-mounted destination is the final tab.
          XCTAssertEqual(midpoint.map(\.id), reserved.map(\.id))
          XCTAssertEqual(midpoint[destination].tabIDs, [detached])
          XCTAssertEqual(midpoint[destination - 1].tabIDs, group.tabIDs.filter { $0 != detached })
          XCTAssertEqual(midpoint[destination - 1].splitGroup, workspace.activeSplit)
          let landed = rows(nil)
          XCTAssertEqual(landed.count, midpoint.count)
          XCTAssertEqual(landed[destination].id, reserved[destination].id)
          XCTAssertEqual(landed.dropFirst(destination).map(\.id), reserved.dropFirst(destination).map(\.id))
          XCTAssertTrue(workspace.validateInvariants())
        }
      }
    }
  }

  func testMovingAcrossDividerPreservesRowAndControlIdentities() throws {
    let space = UUID(), first = UUID(), moved = UUID()
    let before = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [first], temporaryIDs: [moved], groups: [])
    let after = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [first, moved], temporaryIDs: [], groups: [])
    XCTAssertEqual(before.first { $0.draggableTabID == moved }?.id,
                   after.first { $0.draggableTabID == moved }?.id)
    XCTAssertEqual(after.first { $0.draggableTabID == moved }?.tier, .space(space))
    XCTAssertEqual(before.filter { $0.elements == [.divider] || $0.elements == [.newTab] }.map(\.id),
                   after.filter { $0.elements == [.divider] || $0.elements == [.newTab] }.map(\.id))
    XCTAssertEqual(Set(after.map(\.id)).count, after.count)
  }

  func testSplitTabsAreOneContainerInBothTiers() throws {
    let space = UUID(), left = UUID(), right = UUID()
    let group = BrowserSplitLayout(leftTabID: left, rightTabID: right, focusedTabID: right)
    let temporary = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [], temporaryIDs: [left, right], groups: [group])
    let pinned = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [left, right], temporaryIDs: [], groups: [group])
    let row = try XCTUnwrap(temporary.first { $0.splitGroup != nil })
    XCTAssertEqual(row.tabIDs, [left, right])
    XCTAssertEqual(row.draggableTabID, left)
    XCTAssertEqual(row.splitGroup?.focusedTabID, right)
    XCTAssertEqual(pinned.first { $0.splitGroup != nil }?.id, row.id)
    XCTAssertEqual(temporary.filter { !$0.tabIDs.isEmpty }.count, 1)
  }

  func testLiftingEitherSplitMemberMovesTheWholeContainerIntoOneGap() {
    let space = UUID(), left = UUID(), right = UUID(), other = UUID()
    let group = BrowserSplitLayout(leftTabID: left, rightTabID: right)
    for lifted in [left, right] {
      let rows = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [other], temporaryIDs: [left, right],
        groups: [group], liftedID: lifted, drop: .init(tier: .space(space), before: other))
      XCTAssertEqual(rows.flatMap(\.tabIDs), [other])
      XCTAssertEqual(rows.filter { $0.id == .gap(space) }.count, 1)
      XCTAssertEqual(rows.first?.id, .gap(space))
      XCTAssertEqual(rows.first?.tier, .space(space))
    }
  }

  func testDropBeforeRightPanePlacesGapBeforeTheCombinedRow() {
    let space = UUID(), left = UUID(), right = UUID(), incoming = UUID()
    let group = BrowserSplitLayout(leftTabID: left, rightTabID: right)
    let rows = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [left, right], temporaryIDs: [incoming],
      groups: [group], liftedID: incoming, drop: .init(tier: .space(space), before: right))
    XCTAssertEqual(Array(rows.prefix(2).map(\.id)), [.gap(space), .group(group.id)])
  }

  func testEmptyPinsDoNotLeaveABlankContainerAboveDivider() {
    let space = UUID()
    let rows = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [], temporaryIDs: [], groups: [])
    XCTAssertEqual(rows.map(\.id), [.divider(space), .newTab(space), .footer(space)])
    XCTAssertNil(rows[0].draggableTabID)
    XCTAssertNil(rows[1].draggableTabID)
  }

  func testEmptyPinsReserveARowOnlyWhileADragTargetsThem() {
    let space = UUID(), incoming = UUID()
    let rows = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [], temporaryIDs: [incoming],
      groups: [], liftedID: incoming, drop: .init(tier: .space(space), before: nil))
    XCTAssertEqual(rows.map(\.id), [.gap(space), .divider(space), .newTab(space), .footer(space)])
    XCTAssertEqual(rows.first?.tier, .space(space))
  }

  func testIncomingPaneReservesDestinationWithoutRemovingItsSplitRow() throws {
    for count in [2, 3] {
      for pinned in [false, true] {
        let space = UUID(), left = UUID(), right = UUID(), other = UUID()
        let group = BrowserSplitLayout(leftTabID: left, rightTabID: right,
          middleTabID: count == 3 ? UUID() : nil)
        let ids = group.tabIDs + [other]
        let tier: WorkspaceCollection.TabTier = pinned ? .space(space) : .temporary(space)
        let rows = SpaceTabPanelRow.make(spaceID: space,
          pinnedIDs: pinned ? ids : [], temporaryIDs: pinned ? [] : ids,
          groups: [group], drop: .init(tier: tier, before: other))
        let gap = try XCTUnwrap(rows.firstIndex { $0.id == .gap(space) })
        XCTAssertEqual(rows[gap - 1].splitGroup, group)
        XCTAssertEqual(rows[gap + 1].tabIDs, [other])
        XCTAssertEqual(rows.flatMap(\.tabIDs), ids)
        XCTAssertEqual(rows.filter { $0.id == .gap(space) }.count, 1)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
      }
    }
  }

  func testIncomingPaneCanReserveEmptyTierWhileItsSourceGroupStaysTemporary() {
    let space = UUID(), left = UUID(), right = UUID()
    let group = BrowserSplitLayout(leftTabID: left, rightTabID: right)
    let rows = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [], temporaryIDs: group.tabIDs,
      groups: [group], drop: .init(tier: .space(space), before: nil))
    XCTAssertEqual(rows.map(\.id), [.gap(space), .divider(space), .newTab(space), .group(group.id), .footer(space)])
    XCTAssertEqual(rows.first?.tier, .space(space))
    XCTAssertEqual(rows.flatMap(\.tabIDs), group.tabIDs)
  }
}
