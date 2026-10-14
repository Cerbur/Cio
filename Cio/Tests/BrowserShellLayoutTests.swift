@testable import CioUI
import XCTest

final class BrowserShellLayoutTests: XCTestCase {
  func testMainViewTopAndLeftMatchAcrossWindowSizesAndChromeThicknesses() {
    for size in [CGSize(width: 900, height: 500), CGSize(width: 1280, height: 800),
                 CGSize(width: 2048, height: 1350)] {
      for thickness: CGFloat in [28, 44, 56, 72] {
        let bounds = CGRect(origin: CGPoint(x: 3, y: 7), size: size)
        let frames = BrowserShellFrames(bounds: bounds, chromeThickness: thickness)
        XCTAssertEqual(frames.toolbar.height, frames.navigationRail.width)
        XCTAssertEqual(frames.mainView.minX - bounds.minX, frames.mainView.minY - bounds.minY)
        XCTAssertEqual(frames.mainView.minY, frames.toolbar.maxY)
        XCTAssertEqual(frames.mainView.minX, frames.navigationRail.maxX)
        XCTAssertEqual(bounds.maxX - frames.mainView.maxX, 4)
        XCTAssertEqual(bounds.maxY - frames.mainView.maxY, 4)
      }
    }
  }

  func testTrafficLightsHaveEqualRedButtonMarginsAndStayVerticallyCentred() {
    let sizes = [CGSize(width: 14, height: 14), CGSize(width: 14, height: 14),
                 CGSize(width: 14, height: 14)]
    for height: CGFloat in [28, 44, 56, 72] {
      let frames = BrowserShellFrames.trafficLightFrames(sizes: sizes, toolbarHeight: height)
      XCTAssertEqual(frames[0].minX, frames[0].minY)
      for frame in frames { XCTAssertEqual(frame.midY, height / 2) }
      XCTAssertEqual(frames[1].minX - frames[0].maxX, BrowserLayout.trafficLightSpacing)
    }
  }

  func testChromeMetricsKeepControlsCenteredAtPresetAndIntermediateSizes() {
    for scale: CGFloat in [0.5, 0.625, 0.75, 1] {
      let metrics = BrowserChromeMetrics(scale: scale)
      XCTAssertEqual(metrics.thickness, 56 * scale)
      XCTAssertGreaterThanOrEqual(metrics.controlSize, 22)
      XCTAssertLessThan(metrics.controlSize, metrics.thickness)
      XCTAssertEqual(metrics.controlSpacing * 2 + metrics.controlSize, metrics.thickness)
      XCTAssertEqual(metrics.navigationWidth, 2 * metrics.controlSize + 2)
      XCTAssertLessThan(metrics.symbolSize(15), metrics.controlSize)
    }
    XCTAssertEqual(BrowserChromeMetrics(scale: BrowserChromeSize.small.scale).thickness, 28)
    XCTAssertEqual(BrowserChromeMetrics(scale: BrowserChromeSize.standard.scale).thickness, 56)
  }

  func testSplitHandleFitsAboveTheAddressAtEveryChromeSize() {
    for scale: CGFloat in [0.5, 0.625, 0.75, 1] {
      let metrics = BrowserChromeMetrics(scale: scale)
      XCTAssertLessThanOrEqual(metrics.splitHandleSize.height, metrics.controlSpacing)
      XCTAssertGreaterThan(metrics.splitHandleSize.height, 0)
    }
  }

  func testPageToolbarFitsNarrowSplitPanesWithoutOverlappingNavigation() {
    for scale: CGFloat in [0.5, 0.75, 1] {
      let metrics = BrowserChromeMetrics(scale: scale)
      for width: CGFloat in [220, 320, 600, 1000] {
        let bounds = CGRect(x: 0, y: 0, width: width, height: metrics.thickness)
        let frames = BrowserPageToolbarFrames(bounds: bounds, reservedLeadingEdge: 0, metrics: metrics)
        XCTAssertEqual(frames.navigation.midY, bounds.midY)
        XCTAssertEqual(frames.address.midY, bounds.midY)
        XCTAssertGreaterThanOrEqual(frames.address.minX, frames.navigation.maxX)
        XCTAssertLessThanOrEqual(frames.address.maxX, bounds.maxX)
        XCTAssertGreaterThan(frames.address.width, 0)
      }
    }
  }
}
