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

}
