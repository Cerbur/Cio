//
//  NavigationInputTests.swift
//  NativeBrowserTests
//
//  Unit tests for the address/search parser (Milestone 2, section 23).
//
//  NavigationInput.swift is compiled into this target directly, so the tests
//  never start CEF, never touch AppKit and never need the application to run.
//

import XCTest

final class NavigationInputTests: XCTestCase {
  private let engine = GoogleSearchEngine()

  private func parse(_ input: String) -> NavigationInput? {
    parseNavigationInput(input, searchEngine: engine)
  }

  private func assertURL(
    _ input: String,
    _ expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    switch parse(input) {
    case .url(let url):
      XCTAssertEqual(url.absoluteString, expected, "input: \(input)", file: file, line: line)
    default:
      XCTFail("\(input) should parse as a URL, got \(String(describing: parse(input)))", file: file, line: line)
    }
  }

  private func assertSearch(
    _ input: String,
    query expectedQuery: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    switch parse(input) {
    case .search(let query):
      XCTAssertEqual(query, expectedQuery, file: file, line: line)
      XCTAssertEqual(
        engine.searchURL(for: query).absoluteString,
        GoogleSearchEngine().searchURL(for: expectedQuery).absoluteString,
        file: file, line: line)
    default:
      XCTFail("\(input) should parse as a search, got \(String(describing: parse(input)))", file: file, line: line)
    }
  }

  // MARK: - Direct URLs

  func testExplicitHTTPSURL() {
    assertURL("https://example.com", "https://example.com")
  }

  func testExplicitHTTPURL() {
    assertURL("http://example.com", "http://example.com")
  }

  func testBareDomainGetsHTTPS() {
    assertURL("example.com", "https://example.com")
  }

  func testBareDomainWithPathGetsHTTPS() {
    assertURL("github.com/foo/bar", "https://github.com/foo/bar")
  }

  func testLocalhostGetsHTTP() {
    assertURL("localhost", "http://localhost")
  }

  func testLocalhostWithPortGetsHTTP() {
    assertURL("localhost:8080", "http://localhost:8080")
  }

  func testIPv4AddressGetsHTTP() {
    assertURL("127.0.0.1", "http://127.0.0.1")
  }

  func testIPv4AddressWithPortGetsHTTP() {
    assertURL("127.0.0.1:8080", "http://127.0.0.1:8080")
  }

  func testExplicitURLWithPathIsPreserved() {
    assertURL("https://github.com/foo/bar?q=1#frag", "https://github.com/foo/bar?q=1#frag")
  }

  // MARK: - Searches

  func testPlainWordsBecomeASearch() {
    assertSearch("swift objective-c++ cef", query: "swift objective-c++ cef")
  }

  func testSentenceBecomesASearch() {
    assertSearch("how does chromium work", query: "how does chromium work")
  }

  func testChineseQueryBecomesASearch() {
    assertSearch("浏览器 Chromium CEF", query: "浏览器 Chromium CEF")
  }

  func testInvalidHostBecomesASearch() {
    assertSearch("hello:world", query: "hello:world")
  }

  func testSingleWordBecomesASearch() {
    assertSearch("swift", query: "swift")
  }

  // MARK: - Whitespace and empty input

  func testLeadingAndTrailingWhitespaceIsTrimmedForURLs() {
    assertURL("  example.com  ", "https://example.com")
    assertURL("\texample.com\n", "https://example.com")
  }

  func testLeadingAndTrailingWhitespaceIsTrimmedForSearches() {
    assertSearch("  swift objective-c++ cef  ", query: "swift objective-c++ cef")
  }

  func testEmptyInputDoesNotNavigate() {
    XCTAssertNil(parse(""))
  }

  func testWhitespaceOnlyInputDoesNotNavigate() {
    XCTAssertNil(parse("   "))
    XCTAssertNil(parse("\n\t "))
  }

  // MARK: - Search URL encoding

  func testSearchURLUsesGoogle() {
    let url = engine.searchURL(for: "swift")
    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "www.google.com")
    XCTAssertEqual(url.path, "/search")
    XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=swift")
  }

  func testSearchURLPercentEncodesSpaces() {
    XCTAssertEqual(
      engine.searchURL(for: "swift objective-c++ cef").absoluteString,
      "https://www.google.com/search?q=swift%20objective-c%2B%2B%20cef")
  }

  func testSearchURLPercentEncodesUTF8() {
    let url = engine.searchURL(for: "浏览器 Chromium CEF")
    // The query must decode back to exactly what the user typed.
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    XCTAssertEqual(query?.removingPercentEncoding, "q=浏览器 Chromium CEF")
    // No raw spaces or unencoded non-ASCII characters may appear in the URL.
    XCTAssertFalse(url.absoluteString.contains(" "))
    XCTAssertTrue(url.absoluteString.contains("%E6%B5%8F%E8%A7%88%E5%99%A8"))
  }

  func testSearchURLPercentEncodesQuerySeparators() {
    let url = engine.searchURL(for: "a&b=c?d#e").absoluteString
    XCTAssertEqual(url, "https://www.google.com/search?q=a%26b%3Dc%3Fd%23e")
    let query = URLComponents(string: url)?.query
    XCTAssertEqual(query, "q=a&b=c?d#e")
  }

  func testSearchURLValueLeavesUnreservedCharactersAlone() {
    XCTAssertEqual(
      GoogleSearchEngine.percentEncodeQueryValue("aZ0-._~"),
      "aZ0-._~")
  }
}
