import XCTest

final class SpotlightHoverGateTests: XCTestCase {
  func testStationaryPointerDoesNotChangeSelectionAfterRowsMoveUnderIt() {
    var gate = SpotlightHoverGate()
    let pointer = CGPoint(x: 300, y: 200)
    gate.reset(to: pointer)

    XCTAssertFalse(gate.moved(to: pointer))
    XCTAssertFalse(gate.moved(to: pointer))
    XCTAssertTrue(gate.moved(to: CGPoint(x: 302, y: 200)))

    gate.reset(to: CGPoint(x: 302, y: 200))
    XCTAssertFalse(gate.moved(to: CGPoint(x: 302, y: 200)))
    XCTAssertTrue(gate.moved(to: CGPoint(x: 302, y: 202)))
  }
}
