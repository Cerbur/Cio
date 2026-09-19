//
//  NavigationURLPreservationTests.swift
//  NativeBrowserTests
//
//  Regression tests for explicit URLs carrying query parameters (Milestone 2
//  fix session, section 10).
//
//  Motivation: a local development server is reached as
//  "http://127.0.0.1:3080/?token=..." and the whole authentication depends on
//  the query string surviving the address-field path unchanged. These tests
//  pin that down layer by layer: the parser must classify the input as a
//  direct URL, and Foundation must round-trip scheme, host, port, path, query
//  and fragment without rewriting them.
//
//  Only throwaway values appear here - never a real credential.
//

import XCTest

final class NavigationURLPreservationTests: XCTestCase {
  private func parse(_ input: String) -> NavigationInput? {
    parseNavigationInput(input, searchEngine: GoogleSearchEngine())
  }

  /// Asserts the input is a direct URL and returns its components.
  private func parseComponents(
    for input: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> URLComponents? {
    guard case .url(let url) = parse(input) else {
      XCTFail("\(input) should parse as a direct URL", file: file, line: line)
      return nil
    }
    guard let decomposed = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      XCTFail("could not decompose \(url.absoluteString)", file: file, line: line)
      return nil
    }
    return decomposed
  }

  func testLoopbackOriginIsADirectURL() {
    guard let components = parseComponents(for: "http://127.0.0.1:3080/") else { return }
    XCTAssertEqual(components.scheme, "http")
    XCTAssertEqual(components.host, "127.0.0.1")
    XCTAssertEqual(components.port, 3080)
    XCTAssertEqual(components.path, "/")
    XCTAssertNil(components.query)
  }

  func testSingleQueryParameterIsPreserved() {
    guard let components = parseComponents(for: "http://127.0.0.1:3080/?foo=bar") else { return }
    XCTAssertEqual(components.scheme, "http")
    XCTAssertEqual(components.host, "127.0.0.1")
    XCTAssertEqual(components.port, 3080)
    XCTAssertEqual(components.query, "foo=bar")
  }

  func testMultipleQueryParametersArePreserved() {
    guard let components = parseComponents(for: "http://127.0.0.1:3080/?foo=bar&x=y") else { return }
    XCTAssertEqual(components.query, "foo=bar&x=y")
    let items = components.queryItems ?? []
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items.first(where: { $0.name == "foo" })?.value, "bar")
    XCTAssertEqual(items.first(where: { $0.name == "x" })?.value, "y")
  }

  func testTokenQueryParameterIsPreserved() {
    let input = "http://127.0.0.1:3080/?token=test-token_123-abc"
    guard let components = parseComponents(for: input) else { return }
    XCTAssertEqual(components.scheme, "http")
    XCTAssertEqual(components.host, "127.0.0.1")
    XCTAssertEqual(components.port, 3080)
    XCTAssertEqual(components.path, "/")
    XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value,
                   "test-token_123-abc")
    // The whole query survives a round trip through URL(string:).
    XCTAssertEqual(components.url?.absoluteString, input)
  }

  func testLocalhostTokenQueryParameterIsPreserved() {
    let input = "http://localhost:3080/?token=test-token_123-abc"
    guard let components = parseComponents(for: input) else { return }
    XCTAssertEqual(components.scheme, "http")
    XCTAssertEqual(components.host, "localhost")
    XCTAssertEqual(components.port, 3080)
    XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value,
                   "test-token_123-abc")
    XCTAssertEqual(components.url?.absoluteString, input)
  }

  func testFragmentIsPreservedAlongsideQuery() {
    let input = "http://127.0.0.1:3080/?token=test-token_123-abc#section"
    guard let components = parseComponents(for: input) else { return }
    XCTAssertEqual(components.fragment, "section")
    XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value,
                   "test-token_123-abc")
  }

  func testPercentEncodedQuerySurvives() {
    let input = "http://127.0.0.1:3080/?token=a%2Bb%3Dc"
    guard let components = parseComponents(for: input) else { return }
    XCTAssertEqual(components.percentEncodedQuery, "token=a%2Bb%3Dc")
    XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value, "a+b=c")
  }

  func testEmptyQueryValueIsPreserved() {
    guard let components = parseComponents(for: "http://127.0.0.1:3080/?token=") else { return }
    XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value, "")
  }

  func testQueryOrderSurvives() {
    let input = "http://127.0.0.1:3080/?b=2&a=1&token=t"
    guard let components = parseComponents(for: input) else { return }
    XCTAssertEqual(components.queryItems?.map(\.name), ["b", "a", "token"])
  }

  func testSearchResultNeverLeaksIntoTheURLPath() {
    // Plain words must stay a search: no loopback URL is fabricated from them.
    if case .search(let query) = parse("127.0.0.1:3080 token") {
      XCTAssertEqual(query, "127.0.0.1:3080 token")
    } else {
      XCTFail("text with a space must be a search")
    }
  }
}
