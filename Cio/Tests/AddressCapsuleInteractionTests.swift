@testable import CioUI
import XCTest

final class AddressCapsuleInteractionTests: XCTestCase {
  private let capsule = CGRect(x: 120, y: 200, width: 420, height: 36)

  func testFaviconAndReloadTakePriorityOverAddressFocusWithMatchingHitAreas() {
    for dx in [CGFloat(-15), 0, 15] {
      for dy in [CGFloat(-8), 0, 8] {
        let left = CGPoint(x: capsule.minX + 18 + dx, y: capsule.midY + dy)
        let right = CGPoint(x: capsule.maxX - 18 + dx, y: capsule.midY + dy)
        XCTAssertEqual(AddressCapsuleInteraction.target(at: left, in: capsule, hasSuggestions: false),
                       .siteInformation)
        XCTAssertEqual(AddressCapsuleInteraction.target(at: right, in: capsule, hasSuggestions: false),
                       .reloadOrStop)
      }
    }
  }

  func testAddressTextAndSpaceOutsideEndCirclesStillFocusTheEditor() {
    for point in [CGPoint(x: capsule.midX, y: capsule.midY),
                  CGPoint(x: capsule.minX + 35, y: capsule.minY + 1),
                  CGPoint(x: capsule.maxX - 35, y: capsule.minY + 1)] {
      XCTAssertEqual(AddressCapsuleInteraction.target(at: point, in: capsule, hasSuggestions: false), .address)
    }
  }

  func testSuggestionModeDoesNotActivateHiddenEndControls() {
    for x in [capsule.minX + 18, capsule.maxX - 18] {
      XCTAssertEqual(AddressCapsuleInteraction.target(at: CGPoint(x: x, y: capsule.midY),
                                                     in: capsule, hasSuggestions: true), .address)
    }
  }

  func testEndControlsFollowTheActualCapsuleHeight() {
    for height: CGFloat in [18, 27, 36] {
      let frame = CGRect(x: 120, y: 200, width: 240, height: height)
      let radius = height / 2
      XCTAssertEqual(AddressCapsuleInteraction.target(
        at: CGPoint(x: frame.minX + radius, y: frame.midY), in: frame, hasSuggestions: false),
        .siteInformation)
      XCTAssertEqual(AddressCapsuleInteraction.target(
        at: CGPoint(x: frame.maxX - radius, y: frame.midY), in: frame, hasSuggestions: false),
        .reloadOrStop)
      XCTAssertEqual(AddressCapsuleInteraction.target(
        at: CGPoint(x: frame.minX + height + 1, y: frame.midY), in: frame, hasSuggestions: false),
        .address)
    }
  }
}
