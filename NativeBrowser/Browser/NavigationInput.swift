//
//  NavigationInput.swift
//  NativeBrowser
//
//  Parsing of what the user typed into the address field (ARCHITECTURE.md
//  section 20 and the Milestone 2 acceptance criteria).
//
//  This file is deliberately dependency free: Foundation only, no AppKit, no
//  SwiftUI and no CEF. It is compiled into both the application target and the
//  unit test target so the behaviour is testable without starting Chromium
//  (ARCHITECTURE.md section 37).
//

import Foundation

/// What the user's address-field text means.
enum NavigationInput: Equatable {
  /// Load this URL directly.
  case url(URL)
  /// Run this text through the search engine.
  case search(String)
}

/// How non-URL input is turned into a search URL.
protocol SearchEngine {
  func searchURL(for query: String) -> URL
}

/// The search engine used by the browser. Google is enough for this milestone
/// (ARCHITECTURE.md section 20).
struct GoogleSearchEngine: SearchEngine {
  static let endpoint = URL(string: "https://www.google.com/search")!

  func searchURL(for query: String) -> URL {
    var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
    // -percentEncodedQuery is assigned (never string-interpolated) so the query
    // is encoded exactly once, whatever the user typed. URLComponents is
    // already in percent-encoding mode for this component, so the value is
    // percent-encoded here and the resulting query is left untouched.
    components.percentEncodedQuery = "q=" + Self.percentEncodeQueryValue(query)
    return components.url!
  }

  /// Percent-encodes a query value for use inside a URL query component.
  ///
  /// RFC 3986 leaves the query free to contain a wide range of characters, but
  /// a search URL is unambiguous only when the value is fully encoded, so every
  /// character outside the unreserved set (ALPHA / DIGIT / "-" / "." / "_" /
  /// "~") plus the space-to-"+" convention is encoded here.
  static func percentEncodeQueryValue(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }
}

/// Characters that may appear in a host name: ASCII letters and digits, the
/// hyphen and the dot, plus anything non-ASCII so that internationalised
/// domains still navigate instead of being turned into a search.
private let hostCharacterSet: CharacterSet = {
  var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
  set.formUnion(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
  set.formUnion(CharacterSet(charactersIn: "0123456789"))
  set.formUnion(CharacterSet(charactersIn: "-."))
  set.formUnion(CharacterSet(charactersIn: "_"))
  return set
}()

/// Turns address-field text into a navigation decision.
///
/// The rules are intentionally pragmatic rather than a complete omnibox
/// implementation (see the Milestone 2 specification):
///
/// * empty / whitespace-only input never navigates,
/// * text with an explicit scheme is a URL,
/// * `localhost`, `127.0.0.1` and names with a dot are http(s) URLs,
/// * anything with a space, or a host that does not look like one, is a search.
func parseNavigationInput(
  _ input: String,
  searchEngine: SearchEngine = GoogleSearchEngine()
) -> NavigationInput? {
  let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  if let url = directURL(from: trimmed) {
    return .url(url)
  }
  return .search(trimmed)
}

/// Returns the URL to load when `text` should be treated as an address, and
/// `nil` when it should be treated as a search query.
private func directURL(from text: String) -> URL? {
  // An explicit scheme is always honoured.
  //
  // The scheme has to be spelled out rather than detected by URL(string:):
  // that initializer happily parses "localhost" and "127.0.0.1" as URLs whose
  // *scheme* is "localhost" / "127.0.0.1", and a scheme that is not followed by
  // "://" is not something a person types into an address bar.
  if hasExplicitScheme(text), let url = URL(string: text) {
    return url
  }

  let candidate = "https://" + text
  guard let url = URL(string: candidate) else { return nil }
  guard let host = url.host, looksLikeHost(host) else { return nil }

  // A local address is plain http, however the candidate was assembled:
  // `http://localhost` has an unparsable port (see above) while
  // `https://127.0.0.1` parses as https and has to be rewritten.
  if isLocalAddress(url.host) {
    return withHTTP(url)
  }
  return url
}

/// Whether `host` is `localhost` or a loopback-style IPv4 literal.
private func isLocalAddress(_ host: String?) -> Bool {
  guard let host, !host.isEmpty else { return false }
  if host.lowercased() == "localhost" { return true }
  return isIPv4Address(host)
}

/// Schemes that are navigation targets without an authority. Kept deliberately
/// short: anything else that looks like `word:word` is treated as a search
/// rather than being handed to Chromium as a scheme it will refuse.
private let knownSchemes: Set<String> = ["http", "https", "file", "about", "chrome", "data"]

/// Whether the text is an address with an explicit scheme.
///
/// Two shapes qualify:
///
///   * `scheme://...`  - "https://example.com", always a URL
///   * `scheme:...`    - "about:blank", only for `knownSchemes`
///
/// Everything else that merely contains a colon is not given to URL(string:),
/// because that initializer happily invents a scheme for "localhost:8080" and
/// "hello:world".
private func hasExplicitScheme(_ text: String) -> Bool {
  guard let colon = text.firstIndex(of: ":") else { return false }
  let scheme = text[text.startIndex..<colon].lowercased()
  guard let first = scheme.first, first.isLetter else { return false }
  guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
  else { return false }

  let rest = text[text.index(after: colon)...]
  if rest.hasPrefix("//") { return true }
  // `host:port` is not a scheme.
  if rest.allSatisfy({ $0.isNumber }) { return false }
  return knownSchemes.contains(scheme)
}

/// Rewrites a URL's scheme to http.
private func withHTTP(_ url: URL) -> URL? {
  guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
    return nil
  }
  components.scheme = "http"
  return components.url
}

/// Whether a host from a parsed candidate URL is a real host rather than the
/// wreckage of text that merely contains a dot.
private func looksLikeHost(_ host: String) -> Bool {
  if host.contains(":") { return true }  // IPv6 literal.
  if isIPv4Address(host) { return true }

  let labels = host.split(separator: ".", omittingEmptySubsequences: false)
  for label in labels where !label.isEmpty {
    if label.rangeOfCharacter(from: hostCharacterSet.inverted) != nil { return false }
  }

  if host.lowercased() == "localhost" { return true }
  // A dotted name is a host; `example.com`, `github.com`, `foo.bar`.
  return labels.count > 1
}

/// Whether `host` is a dotted-quad IPv4 literal.
private func isIPv4Address(_ host: String) -> Bool {
  let parts = host.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 4 else { return false }
  return parts.allSatisfy { part in
    guard !part.isEmpty, part.count <= 3, let value = Int(part) else { return false }
    return (0...255).contains(value)
  }
}
