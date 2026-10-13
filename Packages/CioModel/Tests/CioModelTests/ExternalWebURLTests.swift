import Foundation
import XCTest
@testable import CioModel

final class ExternalWebURLTests: XCTestCase {
  func testOnlyWebAddressesAreAccepted() {
    for value in ["https://example.com/a?q=%2F#part", "http://localhost:8080", "HTTPS://example.com"] {
      XCTAssertTrue(ExternalWebURL.accepts(URL(string: value)!))
    }
    for value in ["file:///tmp/a", "javascript:alert(1)", "mailto:hello@example.com", "chrome://settings", "https:path", "relative"] {
      XCTAssertFalse(ExternalWebURL.accepts(URL(string: value)!))
    }
  }
}
