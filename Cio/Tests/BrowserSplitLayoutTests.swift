import XCTest

final class BrowserSplitLayoutTests: XCTestCase {
  func testPanesFillAvailableWidthWithOneDividerAndEqualDefaultWidths() {
    let split = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID())
    for width: CGFloat in [700, 900, 1440] {
      let bounds = CGRect(x: 11, y: 7, width: width, height: 800)
      let frames = split.frames(in: bounds, toolbarHeight: 56)
      XCTAssertEqual(frames.left.minX, bounds.minX)
      XCTAssertEqual(frames.left.maxX, frames.divider.minX)
      XCTAssertEqual(frames.divider.maxX, frames.right.minX)
      XCTAssertEqual(frames.right.maxX, bounds.maxX)
      XCTAssertEqual(frames.left.minY, 63)
      XCTAssertEqual(frames.right.maxY, bounds.maxY)
      XCTAssertEqual(frames.left.width, frames.right.width, accuracy: 1)
    }
  }

  func testDraggingToEitherEdgePreservesMinimumPaneWidth() {
    for fraction: CGFloat in [-1, 0, 0.1, 0.9, 1, 2] {
      let split = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: fraction)
      let frames = split.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 700))
      XCTAssertGreaterThanOrEqual(frames.left.width, BrowserSplitLayout.minimumPaneWidth)
      XCTAssertGreaterThanOrEqual(frames.right.width, BrowserSplitLayout.minimumPaneWidth)
    }
  }

  func testNarrowWindowsFallBackToEqualPanesWithoutNegativeFrames() {
    let split = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: 0.01)
    for width: CGFloat in [0, 8, 160, 300, 487] {
      let frames = split.frames(in: CGRect(x: 0, y: 0, width: width, height: 40), toolbarHeight: 56)
      XCTAssertGreaterThanOrEqual(frames.left.width, 0)
      XCTAssertGreaterThanOrEqual(frames.right.width, 0)
      XCTAssertEqual(frames.left.width, frames.right.width, accuracy: 1)
      XCTAssertEqual(frames.left.height, 0)
    }
  }
  func testPlacementPreviewMovesExistingPageAndChromeOppositeTheDropSide() {
    let bounds = CGRect(x: 11, y: 7, width: 1000, height: 700)
    let leftDrop = BrowserSplitLayout.previewFrames(in: bounds, on: .left)
    let rightDrop = BrowserSplitLayout.previewFrames(in: bounds, on: .right)
    XCTAssertEqual(leftDrop.target, rightDrop.survivor)
    XCTAssertEqual(leftDrop.survivor, rightDrop.target)
    XCTAssertEqual(leftDrop.target.minX, bounds.minX)
    XCTAssertEqual(leftDrop.survivor.maxX, bounds.maxX)
    XCTAssertEqual(leftDrop.survivor.minX - leftDrop.target.maxX, BrowserSplitLayout.dividerWidth)
    XCTAssertEqual(leftDrop.target.width, leftDrop.survivor.width)
    XCTAssertEqual(leftDrop.survivor.height, bounds.height)
  }

  func testPreviewOfNarrowExistingPaneDoesNotExposeSpaceBeyondItsChromiumWidth() {
    let bounds = CGRect(x: 11, y: 7, width: 1000, height: 700)
    for side in [BrowserSplitLayout.Side.left, .right] {
      let frames = BrowserSplitLayout.previewFrames(in: bounds, on: side, maximumSurvivorWidth: 240)
      XCTAssertEqual(frames.survivor.width, 240)
      XCTAssertEqual(frames.target.width + frames.survivor.width + BrowserSplitLayout.dividerWidth,
                     bounds.width)
      XCTAssertEqual(min(frames.target.minX, frames.survivor.minX), bounds.minX)
      XCTAssertEqual(max(frames.target.maxX, frames.survivor.maxX), bounds.maxX)
    }
  }

  func testDropZonesAreEqualThirdsWithOffsetBounds() {
    let bounds = CGRect(x: 100, y: 20, width: 900, height: 700)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 100, in: bounds), .left)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 399, in: bounds), .left)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 400, in: bounds), .middle)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 699, in: bounds), .middle)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 700, in: bounds), .right)
  }

  func testTwoPaneInsertionZonesFollowCommittedDividerAndStayStableDuringPreview() {
    let bounds = CGRect(x: 100, y: 20, width: 1200, height: 700)
    for fraction: CGFloat in [0.25, 0.5, 0.75] {
      let split = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: fraction)
      let frames = split.paneFrames(in: bounds)
      let bodyOffset = min(frames.panes[0].width, frames.panes[1].width) / 3
      XCTAssertEqual(split.dropTarget(at: bounds.minX + 12, in: bounds), .init(side: .left))
      XCTAssertEqual(split.dropTarget(at: frames.panes[0].minX + frames.panes[0].width / 3, in: bounds), .init(side: .left, replacesPane: true))
      XCTAssertEqual(split.dropTarget(at: frames.panes[0].midX, in: bounds), .init(side: .left, replacesPane: true))
      XCTAssertEqual(split.dropTarget(at: frames.dividers[0].midX, in: bounds), .init(side: .middle))
      XCTAssertEqual(split.dropTarget(at: frames.dividers[0].midX - bodyOffset, in: bounds), .init(side: .left, replacesPane: true))
      XCTAssertEqual(split.dropTarget(at: frames.dividers[0].midX + bodyOffset, in: bounds), .init(side: .right, replacesPane: true))
      XCTAssertEqual(split.dropTarget(at: frames.panes[1].midX, in: bounds), .init(side: .right, replacesPane: true))
      XCTAssertEqual(split.dropTarget(at: frames.panes[1].maxX - frames.panes[1].width / 3, in: bounds), .init(side: .right, replacesPane: true))
      XCTAssertEqual(split.dropTarget(at: bounds.maxX - 12, in: bounds), .init(side: .right))
      for side in [BrowserSplitLayout.Side.left, .middle, .right] {
        let incoming = UUID()
        let preview = split.placingPane(incoming, on: side)
        XCTAssertEqual(preview.tabIDs.count, 3)
        XCTAssertTrue(split.tabIDs.allSatisfy { preview.contains($0) })
        XCTAssertEqual(preview.tabIDs.firstIndex(of: incoming), side == .left ? 0 : (side == .middle ? 1 : 2))
        XCTAssertEqual(preview.fraction, 1.0 / 3)
        XCTAssertEqual(preview.secondFraction, 2.0 / 3)
        XCTAssertEqual(split.fraction, fraction)
      }
    }
  }

  func testSinglePageInsertionStaysActiveAcrossTheExpandedSlot() {
    let bounds = CGRect(x: 100, y: 20, width: 900, height: 700)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 520, in: bounds), .middle)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 520, in: bounds, previous: .left), .left)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 580, in: bounds, previous: .right), .right)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 560, in: bounds, previous: .left), .middle)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 540, in: bounds, previous: .right), .middle)
    // A dragged pair reserves two of the three columns, including its gap.
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 680, in: bounds, previous: .left, incomingPaneCount: 2), .left)
    XCTAssertEqual(BrowserSplitLayout.dropSide(at: 720, in: bounds, previous: .left, incomingPaneCount: 2), .right)
  }

  func testPairInsertionRemainsActiveInsidePreviewAndReleasesIntoPaneBody() {
    let bounds = CGRect(x: 100, y: 20, width: 1200, height: 700)
    let split = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID())
    XCTAssertEqual(split.dropTarget(at: 350, in: bounds), .init(side: .left, replacesPane: true))
    XCTAssertEqual(split.dropTarget(at: 350, in: bounds, previous: .init(side: .left)), .init(side: .left))
    XCTAssertEqual(split.dropTarget(at: 510, in: bounds, previous: .init(side: .left)), .init(side: .left, replacesPane: true))
    XCTAssertEqual(split.dropTarget(at: 540, in: bounds, previous: .init(side: .middle)), .init(side: .middle))
    XCTAssertEqual(split.dropTarget(at: 860, in: bounds, previous: .init(side: .middle)), .init(side: .middle))
    XCTAssertEqual(split.dropTarget(at: 480, in: bounds, previous: .init(side: .middle)), .init(side: .left, replacesPane: true))
    XCTAssertEqual(split.dropTarget(at: 950, in: bounds, previous: .init(side: .right)), .init(side: .right))
    XCTAssertEqual(split.dropTarget(at: 890, in: bounds, previous: .init(side: .right)), .init(side: .right, replacesPane: true))
  }

  func testUnevenPairEdgesUseTheirOwnPaneAndKeepAccessibleReplacementBodies() {
    let bounds = CGRect(x: 100, y: 20, width: 1200, height: 700)
    let split = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: 0.25)
    XCTAssertEqual(split.dropTarget(at: 1220, in: bounds), .init(side: .right))
    XCTAssertEqual(split.dropTarget(at: 1190, in: bounds), .init(side: .right, replacesPane: true))
    XCTAssertEqual(split.dropTarget(at: 150, in: bounds), .init(side: .left))
    XCTAssertEqual(split.dropTarget(at: 175, in: bounds), .init(side: .left, replacesPane: true))
    XCTAssertEqual(split.dropTarget(at: 455, in: bounds), .init(side: .middle))
    XCTAssertEqual(split.dropTarget(at: 470, in: bounds), .init(side: .right, replacesPane: true))
  }

  func testPaneReorderingAndTripleReplacementUseActualPaneBounds() {
    let bounds = CGRect(x: 100, y: 20, width: 1400, height: 700)
    let pair = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: 0.7)
    let triple = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: 0.2,
                                    middleTabID: UUID(), secondFraction: 0.75)
    for split in [pair, triple] {
      let frames = split.paneFrames(in: bounds)
      for (index, pane) in frames.panes.enumerated() {
        for x in [pane.minX + 1, pane.midX, pane.maxX - 1] {
          XCTAssertEqual(split.dropPaneIndex(at: x, in: bounds), index)
          if split.middleTabID != nil {
            let side: BrowserSplitLayout.Side = index == 0 ? .left : (index == 1 ? .middle : .right)
            XCTAssertEqual(split.dropTarget(at: x, in: bounds), .init(side: side, replacesPane: true))
            let incoming = UUID()
            let preview = split.placingPane(incoming, on: side)
            var expected = split.tabIDs
            expected[index] = incoming
            XCTAssertEqual(preview.tabIDs, expected)
            XCTAssertEqual(preview.fraction, split.fraction)
            XCTAssertEqual(preview.secondFraction, split.secondFraction)
          }
        }
      }
      for (index, divider) in frames.dividers.enumerated() {
        XCTAssertEqual(split.dropPaneIndex(at: divider.midX - 1, in: bounds), index)
        XCTAssertEqual(split.dropPaneIndex(at: divider.midX + 1, in: bounds), index + 1)
      }
    }
  }

  func testTriplePanesFillBoundsAndClampBothDividers() {
    for width: CGFloat in [0, 8, 160, 700, 1000, 1440] {
      for first: CGFloat in [0.01, 1.0 / 3, 0.9] {
        let bounds = CGRect(x: 11, y: 7, width: width, height: 800)
        let split = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: first,
                                       middleTabID: UUID(), secondFraction: 0.95)
        let frames = split.paneFrames(in: bounds)
        XCTAssertEqual(frames.panes.count, 3)
        XCTAssertEqual(frames.dividers.count, 2)
        XCTAssertEqual(frames.panes[0].minX, bounds.minX)
        XCTAssertEqual(frames.panes[2].maxX, bounds.maxX, accuracy: 0.001)
        for index in 0..<2 {
          XCTAssertEqual(frames.panes[index].maxX, frames.dividers[index].minX)
          XCTAssertEqual(frames.dividers[index].maxX, frames.panes[index + 1].minX)
        }
        for pane in frames.panes {
          XCTAssertGreaterThanOrEqual(pane.width, 0)
          if width >= 736 { XCTAssertGreaterThanOrEqual(pane.width, 239) }
        }
      }
    }
  }

}
