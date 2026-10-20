import CioModel
import XCTest

final class RecentTabSwitcherActivationTests: XCTestCase {
  func testQuickReleaseNeverRevealsEvenWhenItsCallbackArrivesLater() {
    var gate = RecentTabSwitcherActivation()
    let token = gate.begin(at: 10, waitsForControl: true)
    XCTAssertFalse(gate.isVisible)
    XCTAssertFalse(gate.reveal(token: token, at: 10.025))
    gate.end()
    XCTAssertFalse(gate.reveal(token: token, at: 11))
    XCTAssertFalse(gate.isVisible)
  }

  func testSustainedHoldRevealsOnceAndSelectionRepeatsDoNotPostponeDeadline() {
    var gate = RecentTabSwitcherActivation()
    let token = gate.begin(at: 10, waitsForControl: true)
    let ids = [UUID(), UUID(), UUID()]
    var selection = RecentTabSelection(candidateIDs: ids, currentID: ids[0], forward: true)
    selection.advance(forward: true)
    XCTAssertFalse(gate.reveal(token: token, at: 10.049))
    XCTAssertTrue(gate.reveal(token: token, at: 10.05))
    XCTAssertEqual(selection.selectedID, ids[2])
    XCTAssertFalse(gate.reveal(token: token, at: 11))
  }

  func testCancelledFlightCannotRevealTheNextGesture() {
    var gate = RecentTabSwitcherActivation()
    let old = gate.begin(at: 10, waitsForControl: true)
    gate.end()
    let next = gate.begin(at: 11, waitsForControl: true)
    XCTAssertFalse(gate.reveal(token: old, at: 12))
    XCTAssertFalse(gate.isVisible)
    XCTAssertTrue(gate.reveal(token: next, at: 12))
  }

  func testMenuInvocationIsImmediatelyVisibleAndEndsCleanly() {
    var gate = RecentTabSwitcherActivation()
    gate.begin(at: 10, waitsForControl: false)
    XCTAssertTrue(gate.isVisible)
    gate.end()
    XCTAssertNil(gate.token)
    XCTAssertFalse(gate.isVisible)
  }
}
