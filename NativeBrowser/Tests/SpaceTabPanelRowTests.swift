import XCTest

final class SpaceTabPanelRowTests: XCTestCase {
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
