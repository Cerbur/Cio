@testable import CioUI
import XCTest

final class BrowserShellLayoutTests: XCTestCase {
  func testMainViewTopAndLeftMatchAcrossWindowSizesAndChromeThicknesses() {
    for size in [CGSize(width: 900, height: 500), CGSize(width: 1280, height: 800),
                 CGSize(width: 2048, height: 1350)] {
      for thickness: CGFloat in [44, 56, 72] {
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
    for height: CGFloat in [44, 56, 72] {
      let frames = BrowserShellFrames.trafficLightFrames(sizes: sizes, toolbarHeight: height)
      XCTAssertEqual(frames[0].minX, frames[0].minY)
      for frame in frames { XCTAssertEqual(frame.midY, height / 2) }
      XCTAssertEqual(frames[1].minX - frames[0].maxX, BrowserLayout.trafficLightSpacing)
    }
  }
}
