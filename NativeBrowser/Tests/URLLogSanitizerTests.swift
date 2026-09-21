//
//  URLLogSanitizerTests.swift
//  NativeBrowserTests
//
//  Pins down the one redaction policy that every production log, lifecycle
//  trace and verification report goes through (see URLLogSanitizer.swift).
//
//  The point of these tests is that a credential cannot reach a log through any
//  of the shapes a browser URL actually takes: a loopback development URL with a
//  token, an OAuth callback with code+state, user-info, a fragment, or a
//  percent-encoded query value.
//
//  Only throwaway values appear here - never a real credential.
//

import XCTest

final class URLLogSanitizerTests: XCTestCase {
  // MARK: - Query values

  /// A. The development URL that motivates the whole policy.
  func testTokenQueryValueIsRedactedAndItsNameSurvives() {
    let output = URLLogSanitizer.sanitized("http://127.0.0.1:3080/?token=super-secret")
    XCTAssertFalse(output.contains("super-secret"))
    XCTAssertEqual(output, "http://127.0.0.1:3080/?token=<redacted>")
  }

  /// B. An OAuth callback: both values go, both names stay.
  func testEveryQueryValueIsRedacted() {
    let output = URLLogSanitizer.sanitized(
      "https://example.com/callback?code=oauth-secret&state=state-secret")
    XCTAssertFalse(output.contains("oauth-secret"))
    XCTAssertFalse(output.contains("state-secret"))
    XCTAssertEqual(output, "https://example.com/<path>?code=<redacted>&state=<redacted>")
  }

  /// An item with no "=" is a bare value, so there is no name to keep.
  func testQueryItemWithoutANameIsRedactedEntirely() {
    let output = URLLogSanitizer.sanitized("https://example.com/?SingleSignedToken")
    XCTAssertFalse(output.contains("SingleSignedToken"))
    XCTAssertEqual(output, "https://example.com/?<redacted>")
  }

  func testQueryOrderAndEmptyValuesSurviveRedaction() {
    let output = URLLogSanitizer.sanitized("http://127.0.0.1:3080/?b=2&a=&token=t")
    XCTAssertEqual(output, "http://127.0.0.1:3080/?b=<redacted>&a=<redacted>&token=<redacted>")
  }

  /// F. Percent-encoded values are redacted exactly like plain ones: nothing is
  /// decoded first, so an encoded secret cannot escape through the log.
  func testPercentEncodedQueryValuesStayRedacted() {
    let encoded = URLLogSanitizer.sanitized("http://127.0.0.1:3080/?token=super%2Dsecret")
    XCTAssertFalse(encoded.contains("super%2Dsecret"))
    XCTAssertFalse(encoded.contains("super-secret"))
    XCTAssertEqual(encoded, "http://127.0.0.1:3080/?token=<redacted>")

    let utf8 = URLLogSanitizer.sanitized("https://www.google.com/search?q=%E6%B5%8F%E8%A7%88%E5%99%A8")
    XCTAssertFalse(utf8.contains("%E6%B5%8F%E8%A7%88%E5%99%A8"))
    XCTAssertFalse(utf8.contains("浏览器"))
    XCTAssertEqual(utf8, "https://www.google.com/<path>?q=<redacted>")
  }

  // MARK: - Credentials and fragments

  /// C. User-info never appears, not even its user name.
  func testUserInfoIsRedacted() {
    let output = URLLogSanitizer.sanitized("https://user:password@example.com/path")
    XCTAssertFalse(output.contains("user"))
    XCTAssertFalse(output.contains("password"))
    XCTAssertEqual(output, "https://<redacted>@example.com/<path>")
  }

  func testUserInfoWithoutAPasswordIsRedacted() {
    let output = URLLogSanitizer.sanitized("https://someone@example.com/path")
    XCTAssertFalse(output.contains("someone"))
    XCTAssertEqual(output, "https://<redacted>@example.com/<path>")
  }

  /// D. The fragment is removed as a whole.
  func testFragmentIsRedacted() {
    let output = URLLogSanitizer.sanitized("https://example.com/path#secret-fragment")
    XCTAssertFalse(output.contains("secret-fragment"))
    XCTAssertEqual(output, "https://example.com/<path>#<redacted>")
  }

  func testFragmentCarryingATokenIsRedacted() {
    let output = URLLogSanitizer.sanitized(
      "https://example.com/callback#access_token=oauth-secret&state=state-secret")
    XCTAssertFalse(output.contains("oauth-secret"))
    XCTAssertFalse(output.contains("state-secret"))
    XCTAssertEqual(output, "https://example.com/<path>#<redacted>")
  }

  /// An "@" in the path is a path, not user-info.
  func testAtSignInThePathIsNotTreatedAsUserInfo() {
    XCTAssertEqual(
      URLLogSanitizer.sanitized("https://example.com/@user/profile"),
      "https://example.com/<path>")
  }

  // MARK: - Useful structure is preserved

  /// E. Even without obvious credentials, path contents are reduced to a
  /// coarse marker so a reset or invite token cannot leak through a route.
  func testURLWithoutSensitivePartsIsUnchanged() {
    XCTAssertEqual(URLLogSanitizer.sanitized("https://example.com/path"), "https://example.com/<path>")
    XCTAssertEqual(URLLogSanitizer.sanitized("https://example.com"), "https://example.com")
    XCTAssertEqual(
      URLLogSanitizer.sanitized("http://127.0.0.1:3080/dashboard"),
      "http://127.0.0.1:3080/<path>")
  }

  func testSchemeHostPortAndPathStayVisible() {
    let output = URLLogSanitizer.sanitized("http://127.0.0.1:3080/deep/link%20name?token=super-secret")
    XCTAssertTrue(output.hasPrefix("http://127.0.0.1:3080/<path>?"))
    XCTAssertFalse(output.contains("super-secret"))
  }

  func testEncodedPathIsPreservedExactly() {
    XCTAssertEqual(
      URLLogSanitizer.sanitized("https://example.com/a%20b/c?x=1"),
      "https://example.com/<path>?x=<redacted>")
  }

  func testURLOverloadAndStringOverloadAgree() {
    let url = URL(string: "https://example.com/callback?code=oauth-secret")!
    XCTAssertEqual(URLLogSanitizer.sanitized(url), URLLogSanitizer.sanitized(url.absoluteString))
    XCTAssertEqual(URLLogSanitizer.sanitized(url), "https://example.com/<path>?code=<redacted>")
  }

  func testMissingURLLogsAsNilRatherThanAnEmptyField() {
    XCTAssertEqual(URLLogSanitizer.sanitized(URL?.none), "nil")
    XCTAssertEqual(URLLogSanitizer.sanitized(URL?.some(URL(string: "https://example.com")!)),
                   "https://example.com")
  }

  // MARK: - Edge cases

  func testEmptyInputStaysEmpty() {
    XCTAssertEqual(URLLogSanitizer.sanitized(""), "")
  }

  /// The sanitizer is a log formatter, so its own output must be safe to feed
  /// back into it (some call sites log an already-sanitized value).
  func testSanitizingIsIdempotent() {
    let inputs = [
      "http://127.0.0.1:3080/?token=super-secret",
      "https://user:password@example.com/path",
      "https://example.com/path#secret-fragment",
      "https://example.com/?SingleSignedToken",
      "https://example.com/path",
    ]
    for input in inputs {
      let once = URLLogSanitizer.sanitized(input)
      XCTAssertEqual(URLLogSanitizer.sanitized(once), once, "input: \(input)")
    }
  }

  /// An opaque URL has no host or path to keep, and its payload is the document
  /// itself, so only the scheme is logged.
  func testOpaqueURLKeepsOnlyItsScheme() {
    let output = URLLogSanitizer.sanitized("data:text/html,<p>super-secret</p>")
    XCTAssertFalse(output.contains("super-secret"))
    XCTAssertEqual(output, "data:<redacted>")

    XCTAssertEqual(URLLogSanitizer.sanitized("about:blank"), "about:<redacted>")
  }

  /// A string that is not a URL at all is not written out.
  func testUnparsableInputIsNotEchoed() {
    XCTAssertEqual(URLLogSanitizer.sanitized("not a url at all"), "<redacted>")
  }

  /// The real search URL shape: only the parameter name survives.
  func testSearchURLFromTheAddressFieldKeepsOnlyTheParameterName() {
    let url = GoogleSearchEngine().searchURL(for: "浏览器 Chromium CEF")
    let output = URLLogSanitizer.sanitized(url)
    XCTAssertEqual(output, "https://www.google.com/<path>?q=<redacted>")
    XCTAssertFalse(output.contains("浏览器"))
  }
}
