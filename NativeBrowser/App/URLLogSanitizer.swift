//
//  URLLogSanitizer.swift
//  NativeBrowser
//
//  The single redaction policy for every URL that is written to a log, to the
//  lifecycle trace or to a self-test report.
//
//  Browser URLs are not safe to log verbatim. A local development session is
//  reached as "http://127.0.0.1:3080/?token=...", an OAuth callback carries
//  "?code=..." and "#access_token=...", and signed URLs carry credentials in
//  their query string. Writing the URL that Chromium reported (or the URL the
//  user typed) into OSLog, into the lifecycle trace or into a verification log
//  therefore publishes a credential.
//
//  Redaction happens on the string form only: what Chromium is asked to load is
//  never touched. BrowserSession and BrowserBridge still hand the original,
//  complete URL to CefFrame::LoadURL (see BrowserSession.load) - only the value
//  that is *observed* passes through here.
//
//  Kept dependency free (Foundation only) so it compiles into both the
//  application target and the unit test bundle, like NavigationInput.swift.
//  The Objective-C++ bridge never formats a URL for a log at all: it hands the
//  URL to CefFrame::LoadURL and this layer is what reports the load, so the
//  policy stays in exactly one place.
//

import Foundation

/// Turns a URL into the form that may be logged or traced.
///
/// Kept visible: scheme, the *presence* of user-info, host, port, path and query
/// parameter names.
///
/// Removed: user name, password, every query parameter value, and the whole
/// fragment (fragments routinely carry "access_token=...").
///
/// The policy is applied consistently, so the same URL always produces the same
/// log text:
///
///     http://127.0.0.1:3080/?token=abcdef
///         -> http://127.0.0.1:3080/?token=<redacted>
///     https://example.com/oauth/callback?code=secret&state=abc#private
///         -> https://example.com/oauth/callback?code=<redacted>&state=<redacted>#<redacted>
///     https://user:password@example.com/path
///         -> https://<redacted>@example.com/path
///
enum URLLogSanitizer {
  /// Written where a value was removed.
  static let redacted = "<redacted>"

  /// The log form of `url`.
  static func sanitized(_ url: URL) -> String {
    sanitized(url.absoluteString)
  }

  /// The log form of an optional URL, which is how the navigation state reports
  /// its main-frame URL. `nil` is reported as "nil" rather than as an empty
  /// field so the log stays unambiguous.
  static func sanitized(_ url: URL?) -> String {
    guard let url else { return "nil" }
    return sanitized(url)
  }

  /// The log form of `rawURL`.
  ///
  /// The string is split from the right - fragment, then query, then the
  /// hierarchical part - so every component keeps its original percent-encoding
  /// and only the removable pieces are replaced.
  static func sanitized(_ rawURL: String) -> String {
    guard !rawURL.isEmpty else { return "" }

    var head = rawURL[...]
    var fragment: Substring?
    if let marker = head.firstIndex(of: "#") {
      fragment = head[head.index(after: marker)...]
      head = head[..<marker]
    }
    var query: Substring?
    if let marker = head.firstIndex(of: "?") {
      query = head[head.index(after: marker)...]
      head = head[..<marker]
    }

    var result = sanitizedHierarchicalPart(head)
    if let query {
      result += "?" + sanitizedQuery(query)
    }
    if fragment != nil {
      // The whole fragment goes: a fragment carries whatever the application
      // put there, and "access_token=..." is a common shape.
      result += "#" + redacted
    }
    return result
  }

  // MARK: - Components

  /// Redacts the user-info of `scheme://user:password@host:port/path`.
  private static func sanitizedHierarchicalPart(_ head: Substring) -> String {
    guard let colon = head.firstIndex(of: ":") else {
      // No scheme at all: nothing about this string can be verified, so none of
      // it is written out.
      return head.isEmpty ? "" : redacted
    }

    let scheme = head[..<colon]
    let rest = head[head.index(after: colon)...]
    guard rest.hasPrefix("//") else {
      // An opaque URL: "data:", "mailto:", "about:", "javascript:". Its payload
      // cannot be inspected for credentials - a data: URL *is* the document -
      // so only the scheme is kept.
      return rest.isEmpty ? "\(scheme):" : "\(scheme):\(redacted)"
    }

    let hierarchical = rest.dropFirst(2)
    guard let slash = hierarchical.firstIndex(of: "/") else {
      return "\(scheme)://\(sanitizedAuthority(hierarchical))"
    }
    return
      "\(scheme)://\(sanitizedAuthority(hierarchical[..<slash]))\(hierarchical[slash...])"
  }

  /// Replaces the user-info of an authority ("user:password@host:port").
  ///
  /// Only the authority is examined, so an "@" in the path (for example
  /// "https://example.com/@user") is left alone.
  private static func sanitizedAuthority(_ authority: Substring) -> String {
    // The last "@" is the separator: a password may itself contain one.
    guard let separator = authority.lastIndex(of: "@") else { return String(authority) }
    return redacted + "@" + authority[authority.index(after: separator)...]
  }

  /// Keeps query parameter names and removes every value.
  ///
  /// "code=secret&state=abc" becomes "code=<redacted>&state=<redacted>". An item
  /// with no "=" has no name to keep - it is a bare value, for example a single
  /// signed token - so the whole item is redacted.
  ///
  /// Nothing is percent-decoded first: an encoded value is redacted exactly like
  /// a plain one, so "token=super%2Dsecret" cannot smuggle its value out.
  private static func sanitizedQuery(_ query: Substring) -> String {
    guard !query.isEmpty else { return "" }
    return
      query
      .split(separator: "&", omittingEmptySubsequences: false)
      .map { item in
        guard let equals = item.firstIndex(of: "=") else {
          return item.isEmpty ? "" : redacted
        }
        return "\(item[..<equals])=\(redacted)"
      }
      .joined(separator: "&")
  }
}
