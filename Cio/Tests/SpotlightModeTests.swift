@testable import CioEngine
@testable import CioUI
import XCTest

final class SpotlightModeTests: XCTestCase {
  func testWebsiteOffersDirectVisitThenGoogleSearch() {
    let suggestions = SpotlightMode.suggestions(for: "example.com/path")
    XCTAssertEqual(suggestions.count, 2)
    XCTAssertEqual(suggestions[0], .website(URL(string: "https://example.com/path")!))
    XCTAssertEqual(suggestions[0].action,
                   .openTab(URL(string: "https://example.com/path")!))
    XCTAssertEqual(suggestions[1].action,
                   .openTab(URL(string: "https://www.google.com/search?q=example.com%2Fpath")!))
  }

  func testQuestionOffersGoogleSearch() {
    let suggestions = SpotlightMode.suggestions(for: "how to code")
    XCTAssertEqual(suggestions.count, 1)
    XCTAssertEqual(suggestions[0], .googleSearch("how to code"))
    XCTAssertEqual(suggestions[0].action,
                   .openTab(URL(string: "https://www.google.com/search?q=how%20to%20code")!))
  }

  func testWhitespaceHasNoSuggestions() {
    XCTAssertTrue(SpotlightMode.suggestions(for: " \n ").isEmpty)
  }
}
