import CioModel
@testable import CioUI
import XCTest

final class SidebarTabDragOverviewTests: XCTestCase {
  func testFirstSpaceEntersOverviewAtOverscrollThresholdIncludingCappedThreshold() {
    for (width, threshold): (CGFloat, CGFloat) in [(200, 44), (600, 72)] {
      XCTAssertFalse(SpacePaging.entersOverview(current: 0, displacement: threshold - 0.01, width: width))
      XCTAssertTrue(SpacePaging.entersOverview(current: 0, displacement: threshold, width: width))
      XCTAssertTrue(SpacePaging.entersOverview(current: 0, displacement: threshold + 1, width: width))
      XCTAssertFalse(SpacePaging.entersOverview(current: 0, displacement: -threshold, width: width))
    }
  }

  func testOtherSpacesNeverEnterOverviewFromOverscroll() {
    for current in 1...3 {
      for displacement: CGFloat in [-1000, -72, 0, 72, 1000] {
        XCTAssertFalse(SpacePaging.entersOverview(current: current, displacement: displacement, width: 200))
      }
    }
  }

  func testOrdinarySpacePagingMovesOneSpaceAndRemainsBounded() {
    for (width, threshold): (CGFloat, CGFloat) in [(200, 44), (600, 72)] {
      for count in [1, 4] {
        for current in 0..<count {
          for displacement in [threshold, CGFloat(1000)] {
            XCTAssertEqual(SpacePaging.destinationIndex(current: current, count: count,
              displacement: displacement, width: width), max(0, current - 1))
            XCTAssertEqual(SpacePaging.destinationIndex(current: current, count: count,
              displacement: -displacement, width: width), min(count - 1, current + 1))
          }
          for displacement in [CGFloat.zero, threshold - 0.01, -threshold + 0.01] {
            XCTAssertEqual(SpacePaging.destinationIndex(current: current, count: count,
              displacement: displacement, width: width), current)
          }
        }
      }
    }
  }

  func testSpacePagingIgnoresMissingWidthOrEmptySpaceList() {
    for width: CGFloat in [0, -200] {
      XCTAssertFalse(SpacePaging.entersOverview(current: 0, displacement: 1000, width: width))
      XCTAssertEqual(SpacePaging.destinationIndex(current: 1, count: 3,
        displacement: -1000, width: width), 1)
    }
    XCTAssertEqual(SpacePaging.destinationIndex(current: 0, count: 0, displacement: -1000, width: 200), 0)
  }

  func testOrdersResolveBySpaceAndOnlySelectedSpaceUsesLegacyFallback() {
    let selected = UUID(), other = UUID(), unknown = UUID()
    let pin = UUID(), temporary = UUID(), otherPin = UUID(), otherTemporary = UUID()
    var layout = SidebarTabDragLayout(spaceID: selected, globalTabIDs: [], globalPinnedTabCount: 0,
      groupedTabIDs: [], spacePinTabIDs: [pin], temporaryTabIDs: [temporary],
      tileSize: .zero, topInset: 0,
      spaceOrders: [other: .init(pinnedTabIDs: [otherPin], temporaryTabIDs: [otherTemporary])])
    XCTAssertEqual(layout.tabIDs(in: .space(selected)), [pin])
    XCTAssertEqual(layout.tabIDs(in: .temporary(selected)), [temporary])
    XCTAssertEqual(layout.tabIDs(in: .space(other)), [otherPin])
    XCTAssertEqual(layout.tabIDs(in: .temporary(other)), [otherTemporary])
    XCTAssertEqual(layout.tabIDs(in: .space(unknown)), [])
    XCTAssertEqual(layout.tabIDs(in: .temporary(unknown)), [])
    layout.spaceOrders[selected] = .init(pinnedTabIDs: [], temporaryTabIDs: [])
    XCTAssertEqual(layout.tabIDs(in: .space(selected)), [])
    XCTAssertEqual(layout.tabIDs(in: .temporary(selected)), [])
  }

  @MainActor
  func testLiftFromUnselectedColumnAndCommitToSelectedColumn() {
    let fixture = Fixture()
    fixture.move(from: fixture.otherPoint, to: fixture.selectedPoint)
    XCTAssertEqual(fixture.drag.tabID, fixture.otherTab)
    XCTAssertEqual(fixture.drag.target, .init(tier: .temporary(fixture.selected), before: fixture.selectedTab))
    XCTAssertEqual(fixture.drag.sidebarLiftedTabIDs, [fixture.otherTab])
    XCTAssertEqual(fixture.drag.style, .row)
    XCTAssertEqual(fixture.drag.anchor, fixture.selectedPoint)
    var committed = false
    fixture.drag.drop { id, target in
      committed = true
      XCTAssertEqual(id, fixture.otherTab)
      XCTAssertEqual(target, .init(tier: .temporary(fixture.selected), before: fixture.selectedTab))
      return true
    }
    XCTAssertTrue(committed)
    XCTAssertNil(fixture.drag.hoveredSpaceID)
    XCTAssertEqual(fixture.drag.autoscrollDirection, 0)
  }

  @MainActor
  func testDestinationUsesItsOwnDividerAndCanReceiveIntoEmptyTiers() {
    let fixture = Fixture()
    fixture.layout.spaceOrders[fixture.other] = .init(pinnedTabIDs: [], temporaryTabIDs: [])
    // Keep the selected Space's legacy header deliberately unrelated.
    fixture.drag.spaceHeaderFrame = CGRect(x: 0, y: 0, width: 200, height: 500)
    let divider = SpaceTabPanelRow.make(spaceID: fixture.other, pinnedIDs: [], temporaryIDs: [], groups: [])[0]
    fixture.drag.register(divider, frame: CGRect(x: 230, y: 190, width: 180, height: 20), token: UUID())
    fixture.move(to: CGPoint(x: 250, y: 180))
    XCTAssertEqual(fixture.drag.target, .init(tier: .space(fixture.other), before: nil))
    fixture.move(to: CGPoint(x: 250, y: 220))
    XCTAssertEqual(fixture.drag.target, .init(tier: .temporary(fixture.other), before: nil))
    fixture.move(to: CGPoint(x: 250, y: 120))
    XCTAssertEqual(fixture.drag.target, .init(tier: .space(fixture.other), before: nil))
    XCTAssertEqual(fixture.drag.hoveredSpaceID, fixture.other)
    XCTAssertEqual(fixture.drag.autoscrollDirection, 0)
  }

  @MainActor
  func testColumnsAlongsideTopPinsRemainRowsAndGlobalPinsStillReceive() {
    let fixture = Fixture()
    fixture.drag.topPinFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
    fixture.drag.registerSpaceViewport(fixture.other, frame: CGRect(x: 220, y: 0, width: 200, height: 600))
    fixture.drag.registerSpaceHeader(fixture.other, frame: CGRect(x: 220, y: 0, width: 200, height: 40))
    fixture.move(to: CGPoint(x: 250, y: 70))
    XCTAssertEqual(fixture.drag.target?.tier, .temporary(fixture.other))
    XCTAssertEqual(fixture.drag.style, .row)
    fixture.move(to: CGPoint(x: 100, y: 70))
    XCTAssertEqual(fixture.drag.target, .init(tier: .global, before: nil))
    XCTAssertEqual(fixture.drag.style, .tile)
    XCTAssertNil(fixture.drag.hoveredSpaceID)
  }

  @MainActor
  func testAutoscrollTransfersBetweenColumnsWithoutDirectionChange() {
    let fixture = Fixture()
    fixture.move(to: CGPoint(x: 100, y: 590))
    XCTAssertEqual(fixture.drag.autoscrollDirection, 1)
    XCTAssertTrue(fixture.drag.isAutoscrolling(in: fixture.selected))
    XCTAssertFalse(fixture.drag.isAutoscrolling(in: fixture.other))
    fixture.move(to: CGPoint(x: 250, y: 590))
    XCTAssertEqual(fixture.drag.autoscrollDirection, 1)
    XCTAssertEqual(fixture.drag.hoveredSpaceID, fixture.other)
    XCTAssertFalse(fixture.drag.isAutoscrolling(in: fixture.selected))
    XCTAssertTrue(fixture.drag.isAutoscrolling(in: fixture.other))
    fixture.move(to: CGPoint(x: 250, y: 150))
    XCTAssertEqual(fixture.drag.autoscrollDirection, -1)
    fixture.drag.gestureDidEnd()
    XCTAssertNil(fixture.drag.hoveredSpaceID)
    XCTAssertFalse(fixture.drag.isAutoscrolling(in: fixture.other))
  }

  @MainActor
  func testColumnGapsAndPointsOutsideRootDoNotReceiveOrScroll() {
    let fixture = Fixture()
    for point in [CGPoint(x: 210, y: 590), CGPoint(x: 430, y: 590),
                  CGPoint(x: 250, y: 610), CGPoint(x: 250, y: 90)] {
      fixture.move(to: point)
      XCTAssertNil(fixture.drag.target)
      XCTAssertNil(fixture.drag.hoveredSpaceID)
      XCTAssertEqual(fixture.drag.autoscrollDirection, 0)
    }
  }

  @MainActor
  func testRowsUnderHeaderAndOutsideRootCannotBeLifted() {
    for (frame, point) in [
      (CGRect(x: 230, y: 110, width: 180, height: 36), CGPoint(x: 250, y: 125)),
      (CGRect(x: 230, y: 610, width: 180, height: 36), CGPoint(x: 250, y: 625)),
      (CGRect(x: 430, y: 180, width: 180, height: 36), CGPoint(x: 450, y: 195)),
    ] {
      let fixture = Fixture()
      fixture.drag.register(fixture.otherTab, in: .temporary(fixture.other), frame: frame, token: UUID())
      fixture.move(from: point, to: fixture.selectedPoint)
      XCTAssertFalse(fixture.drag.isDragging)
      XCTAssertNil(fixture.drag.target)
    }
  }

  @MainActor
  func testBelowViewportBoundaryAvoidsAppendingPastUnseenRowsAndKeepsGapStable() throws {
    let fixture = Fixture()
    let belowViewport = UUID(), last = UUID()
    fixture.layout.spaceOrders[fixture.other]?.temporaryTabIDs.append(contentsOf: [belowViewport, last])
    fixture.drag.register(belowViewport, in: .temporary(fixture.other),
      frame: CGRect(x: 230, y: 650, width: 180, height: 36), token: UUID())
    fixture.drag.register(last, in: .temporary(fixture.other),
      frame: CGRect(x: 230, y: 700, width: 180, height: 36), token: UUID())
    fixture.move(to: CGPoint(x: 250, y: 590))
    let target = SidebarTabDropTarget(tier: .temporary(fixture.other), before: belowViewport)
    XCTAssertEqual(fixture.drag.target, target)
    let rows = SpaceTabPanelRow.make(spaceID: fixture.other, pinnedIDs: [],
      temporaryIDs: [fixture.otherTab, belowViewport, last], groups: [], liftedID: fixture.selectedTab,
      drop: .init(tier: target.tier, before: target.before))
    let gap = try XCTUnwrap(rows.first { $0.id == .gap(fixture.other) })
    fixture.drag.register(gap, frame: CGRect(x: 230, y: 570, width: 180, height: 36), token: UUID())
    fixture.drag.register(belowViewport, in: .temporary(fixture.other),
      frame: CGRect(x: 230, y: 540, width: 180, height: 36), token: UUID())
    fixture.drag.listDidScroll()
    XCTAssertEqual(fixture.drag.target, target, "Reflow must keep the target while the pointer remains in the gap")
  }

  @MainActor
  func testPointerInsideDestinationGapKeepsItsBoundaryDuringReflow() throws {
    let fixture = Fixture()
    fixture.move(to: fixture.otherPoint)
    let target = try XCTUnwrap(fixture.drag.target)
    let rows = SpaceTabPanelRow.make(spaceID: fixture.other, pinnedIDs: [],
      temporaryIDs: [fixture.otherTab], groups: [], liftedID: fixture.selectedTab,
      drop: .init(tier: target.tier, before: target.before))
    let gap = try XCTUnwrap(rows.first { $0.id == .gap(fixture.other) })
    fixture.drag.register(gap, frame: CGRect(x: 230, y: 180, width: 180, height: 36), token: UUID())
    // A reflow notification can briefly report the neighbouring row above
    // the pointer while the pointer is still inside its reserved gap.
    fixture.drag.register(fixture.otherTab, in: .temporary(fixture.other),
      frame: CGRect(x: 230, y: 140, width: 180, height: 36), token: UUID())
    fixture.drag.listDidScroll()
    XCTAssertEqual(fixture.drag.target, target)
  }

  @MainActor
  func testSplitDestinationUsesOneCombinedRowBoundary() throws {
    let fixture = Fixture()
    let right = UUID()
    let group = BrowserSplitLayout(leftTabID: fixture.otherTab, rightTabID: right)
    fixture.layout.spaceOrders[fixture.other]?.temporaryTabIDs.append(right)
    let row = try XCTUnwrap(SpaceTabPanelRow.make(spaceID: fixture.other, pinnedIDs: [],
      temporaryIDs: group.tabIDs, groups: [group]).first { $0.splitGroup != nil })
    fixture.drag.register(row, frame: CGRect(x: 230, y: 180, width: 180, height: 36), token: UUID())
    fixture.move(to: fixture.otherPoint)
    XCTAssertEqual(fixture.drag.target, .init(tier: .temporary(fixture.other), before: fixture.otherTab))
    fixture.move(to: CGPoint(x: 250, y: 210))
    XCTAssertEqual(fixture.drag.target, .init(tier: .temporary(fixture.other), before: nil))
  }

  @MainActor
  func testObsoleteTierRegistrationCannotLiftTabFromPreviousSpace() {
    let fixture = Fixture()
    fixture.drag.unregister(fixture.otherTab, in: .temporary(fixture.other), token: fixture.otherToken)
    fixture.drag.register(fixture.selectedTab, in: .temporary(fixture.other),
      frame: CGRect(x: 230, y: 180, width: 180, height: 36), token: UUID())
    fixture.move(from: fixture.otherPoint, to: fixture.selectedPoint)
    XCTAssertFalse(fixture.drag.isDragging)
  }

  @MainActor
  func testRemovedSpaceStopsReceivingDespiteRetainedViewportGeometry() {
    let fixture = Fixture()
    fixture.move(to: CGPoint(x: 250, y: 590))
    XCTAssertTrue(fixture.drag.isAutoscrolling(in: fixture.other))
    fixture.layout.spaceOrders[fixture.other] = nil
    fixture.drag.listDidScroll()
    XCTAssertNil(fixture.drag.target)
    XCTAssertNil(fixture.drag.hoveredSpaceID)
    XCTAssertEqual(fixture.drag.autoscrollDirection, 0)
  }

  @MainActor
  func testOldViewportAndHeaderCleanupCannotRemoveReplacementGeometry() {
    let fixture = Fixture()
    let old = UUID(), replacement = UUID()
    let viewport = CGRect(x: 220, y: 100, width: 200, height: 500)
    let header = CGRect(x: 220, y: 100, width: 200, height: 40)
    fixture.drag.registerSpaceViewport(fixture.other, frame: viewport, token: old)
    fixture.drag.registerSpaceHeader(fixture.other, frame: header, token: old)
    fixture.drag.registerSpaceViewport(fixture.other, frame: viewport, token: replacement)
    fixture.drag.registerSpaceHeader(fixture.other, frame: header, token: replacement)
    fixture.drag.unregisterSpaceViewport(fixture.other, token: old)
    fixture.drag.unregisterSpaceHeader(fixture.other, token: old)
    fixture.move(to: CGPoint(x: 250, y: 120))
    XCTAssertEqual(fixture.drag.target?.tier, .space(fixture.other))
    fixture.move(to: CGPoint(x: 250, y: 590))
    XCTAssertTrue(fixture.drag.isAutoscrolling(in: fixture.other))
    fixture.drag.unregisterSpaceViewport(fixture.other, token: replacement)
    XCTAssertNil(fixture.drag.target)
    XCTAssertNil(fixture.drag.hoveredSpaceID)
    XCTAssertEqual(fixture.drag.autoscrollDirection, 0)
  }

  @MainActor
  func testReturningSplitGroupToHomeDoesNotCommitOrTargetItsOwnMembers() {
    let fixture = Fixture()
    let right = UUID(), next = UUID()
    let group = BrowserSplitLayout(leftTabID: fixture.otherTab, rightTabID: right)
    fixture.layout.spaceOrders[fixture.other]?.temporaryTabIDs = [fixture.otherTab, right, next]
    fixture.layout.groupedTabIDs = Set(group.tabIDs)
    fixture.drag.splitGroupProvider = { group.contains($0) ? group : nil }
    fixture.drag.register(next, in: .temporary(fixture.other),
      frame: CGRect(x: 230, y: 230, width: 180, height: 36), token: UUID())
    fixture.move(from: fixture.otherPoint, to: fixture.selectedPoint)
    XCTAssertEqual(fixture.drag.sidebarLiftedTabIDs, Set(group.tabIDs))
    fixture.move(from: fixture.otherPoint, to: fixture.otherPoint)
    XCTAssertEqual(fixture.drag.target, .init(tier: .temporary(fixture.other), before: next))
    fixture.drag.drop { _, _ in
      XCTFail("Returning to the original split-group slot must not move it")
      return true
    }
  }

  @MainActor
  func testOffscreenDestinationEndsOverlayWithoutFlyingToHiddenRow() {
    let fixture = Fixture()
    fixture.move(to: fixture.otherPoint)
    fixture.drag.drop { _, _ in true }
    let anchor = fixture.drag.anchor
    fixture.drag.register(fixture.selectedTab, in: .temporary(fixture.other),
      frame: CGRect(x: 230, y: 650, width: 180, height: 36), token: UUID())
    XCTAssertNil(fixture.drag.tabID)
    XCTAssertEqual(fixture.drag.anchor, anchor)
  }

  @MainActor
  func testNormalModeReservationDoesNotChaseAnimatedNeighbours() throws {
    let fixture = Fixture()
    fixture.drag.isSpaceOverview = false
    let next = UUID()
    fixture.layout.temporaryTabIDs.append(next)
    fixture.drag.register(next, in: .temporary(fixture.selected),
      frame: CGRect(x: 10, y: 230, width: 180, height: 36), token: UUID())
    fixture.move(to: CGPoint(x: 100, y: 225))
    let target = try XCTUnwrap(fixture.drag.target)
    XCTAssertEqual(target, .init(tier: .temporary(fixture.selected), before: next))
    let gap = try XCTUnwrap(SpaceTabPanelRow.make(spaceID: fixture.selected,
      pinnedIDs: [], temporaryIDs: [fixture.selectedTab, next], groups: [],
      liftedID: fixture.selectedTab, drop: .init(tier: target.tier, before: target.before))
      .first { $0.id == .gap(fixture.selected) })
    fixture.drag.register(gap, frame: CGRect(x: 10, y: 210, width: 180, height: 36), token: UUID())
    for y: CGFloat in [200, 205, 210, 205, 200] {
      fixture.drag.register(next, in: .temporary(fixture.selected),
        frame: CGRect(x: 10, y: y, width: 180, height: 36), token: UUID())
      fixture.drag.listDidScroll()
      fixture.move(to: CGPoint(x: 100, y: 225))
      XCTAssertEqual(fixture.drag.target, target, "A stationary pointer must not reverse a row's flight")
    }
    fixture.move(to: CGPoint(x: 100, y: 280))
    XCTAssertEqual(fixture.drag.target, .init(tier: .temporary(fixture.selected), before: nil),
      "Leaving the reservation must still select another boundary immediately")
  }

  @MainActor
  func testReservationKeepsTierWhenAnimatedDividerCrossesPointer() throws {
    for overview in [false, true] {
      let fixture = Fixture()
      fixture.drag.isSpaceOverview = overview
      fixture.move(to: CGPoint(x: 100, y: 225))
      let target = try XCTUnwrap(fixture.drag.target)
      XCTAssertEqual(target.tier, .temporary(fixture.selected))
      let gap = try XCTUnwrap(SpaceTabPanelRow.make(spaceID: fixture.selected,
        pinnedIDs: [], temporaryIDs: [fixture.selectedTab], groups: [],
        liftedID: fixture.selectedTab, drop: .init(tier: target.tier, before: target.before))
        .first { $0.id == .gap(fixture.selected) })
      fixture.drag.register(gap, frame: CGRect(x: 10, y: 210, width: 180, height: 36), token: UUID())
      let divider = SpaceTabPanelRow(id: .divider(fixture.selected), elements: [.divider], tier: nil)
      fixture.drag.register(divider, frame: CGRect(x: 10, y: 235, width: 180, height: 20), token: UUID())
      fixture.drag.listDidScroll()
      fixture.move(to: CGPoint(x: 100, y: 225))
      XCTAssertEqual(fixture.drag.target, target)
      fixture.move(to: CGPoint(x: 100, y: 150))
      XCTAssertEqual(fixture.drag.target?.tier, .space(fixture.selected),
        "Leaving the gap must allow crossing the divider without waiting for animation")
    }
  }

  @MainActor
  func testTopPinReservationDoesNotChaseAnimatedTiles() throws {
    let fixture = Fixture()
    fixture.drag.isSpaceOverview = false
    fixture.drag.topPinFrame = CGRect(x: 0, y: 0, width: 200, height: 80)
    let next = UUID()
    fixture.layout.globalTabIDs = [next]
    fixture.drag.register(next, in: .global,
      frame: CGRect(x: 10, y: 20, width: 80, height: 40), token: UUID())
    fixture.move(to: CGPoint(x: 30, y: 35))
    let target = try XCTUnwrap(fixture.drag.target)
    XCTAssertEqual(target, .init(tier: .global, before: next))
    let gap = try XCTUnwrap(SpaceTabPanelRow.makeTabs([next], spaceID: fixture.selected, tier: .global,
      groups: [], liftedID: fixture.selectedTab, drop: .init(tier: target.tier, before: target.before))
      .first { $0.id == .gap(fixture.selected) })
    fixture.drag.register(gap, frame: CGRect(x: 10, y: 20, width: 80, height: 40), token: UUID())
    for x: CGFloat in [-40, -20, -10, -40] {
      fixture.drag.register(next, in: .global,
        frame: CGRect(x: x, y: 20, width: 80, height: 40), token: UUID())
      fixture.drag.listDidScroll()
      fixture.move(to: CGPoint(x: 30, y: 35))
      XCTAssertEqual(fixture.drag.target, target)
    }
    fixture.move(to: CGPoint(x: 130, y: 35))
    XCTAssertEqual(fixture.drag.target, .init(tier: .global, before: nil))
  }

  @MainActor
  func testNormalModeKeepsSelectedSpaceViewportAndTierTargeting() {
    let fixture = Fixture()
    fixture.drag.isSpaceOverview = false
    fixture.drag.register(.space(fixture.selected), frame: CGRect(x: 10, y: 140, width: 180, height: 20))
    fixture.move(to: CGPoint(x: 100, y: 150))
    XCTAssertEqual(fixture.drag.target?.tier, .space(fixture.selected))
    fixture.move(to: CGPoint(x: 100, y: 590))
    XCTAssertEqual(fixture.drag.target?.tier, .temporary(fixture.selected))
    XCTAssertTrue(fixture.drag.isAutoscrolling(in: fixture.selected))
    fixture.drag.gestureDidEnd()
    fixture.move(from: fixture.otherPoint, to: fixture.otherPoint)
    XCTAssertFalse(fixture.drag.isDragging)
  }

  @MainActor
  private final class Fixture {
    let selected = UUID(), other = UUID()
    let selectedTab = UUID(), otherTab = UUID(), otherToken = UUID()
    let selectedPoint = CGPoint(x: 100, y: 190)
    let otherPoint = CGPoint(x: 250, y: 190)
    let drag = SidebarTabDrag()
    var layout: SidebarTabDragLayout

    init() {
      layout = SidebarTabDragLayout(spaceID: selected, globalTabIDs: [], globalPinnedTabCount: 0,
        groupedTabIDs: [], spacePinTabIDs: [], temporaryTabIDs: [selectedTab],
        tileSize: CGSize(width: 80, height: 40), topInset: 0,
        spaceOrders: [other: .init(pinnedTabIDs: [], temporaryTabIDs: [otherTab])])
      drag.reduceMotion = true
      drag.isSpaceOverview = true
      drag.bounds = CGRect(x: 0, y: 0, width: 420, height: 600)
      drag.spaceFrame = CGRect(x: 0, y: 100, width: 200, height: 500)
      drag.spaceHeaderFrame = CGRect(x: 0, y: 100, width: 200, height: 40)
      drag.registerSpaceViewport(selected, frame: drag.spaceFrame)
      drag.registerSpaceHeader(selected, frame: drag.spaceHeaderFrame)
      drag.registerSpaceViewport(other, frame: CGRect(x: 220, y: 100, width: 200, height: 500))
      drag.registerSpaceHeader(other, frame: CGRect(x: 220, y: 100, width: 200, height: 40))
      drag.register(selectedTab, in: .temporary(selected),
        frame: CGRect(x: 10, y: 180, width: 180, height: 36), token: UUID())
      drag.register(otherTab, in: .temporary(other),
        frame: CGRect(x: 230, y: 180, width: 180, height: 36), token: otherToken)
      drag.layoutProvider = { [weak self] in self?.layout }
    }

    func move(from start: CGPoint? = nil, to point: CGPoint) {
      drag.pointerMoved(from: start ?? selectedPoint, to: point, layout: layout)
    }
  }
}
