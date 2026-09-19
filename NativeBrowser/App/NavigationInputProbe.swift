//
//  NavigationInputProbe.swift
//  NativeBrowser
//
//  Standalone entry point for the address-field parser:
//
//    NativeBrowser --parse-navigation-input="localhost:8080"
//    -> parsed-as-url http://localhost:8080
//
//  Used by Scripts/verify_milestone2.sh to check the parser against the exact
//  expectations in the Milestone 2 specification. It deliberately runs before
//  CEF is initialized and exits immediately, so it proves the parser is usable
//  without Chromium. The unit tests in Tests/ are the primary coverage; this
//  probe exists so the verification script can check the shipped binary.
//
//  This output is a trace: it is captured into a log file by the verification
//  script and a developer may point the probe at an address that carries a
//  token, so the URL is printed in sanitized form and the raw query text is
//  never echoed (see URLLogSanitizer).
//

import Foundation

enum NavigationInputProbe {
  private static let prefix = "--parse-navigation-input="

  /// Whether this process was asked to parse one navigation input.
  static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.contains { $0.hasPrefix(prefix) }
  }

  /// Parses every --parse-navigation-input argument, prints the result and
  /// exits. Empty input is reported as empty rather than treated as an error.
  static func run(arguments: [String] = CommandLine.arguments) -> Never {
    for argument in arguments where argument.hasPrefix(prefix) {
      let input = String(argument.dropFirst(prefix.count))
      switch parseNavigationInput(input) {
      case .url(let url):
        print("parsed-as-url \(URLLogSanitizer.sanitized(url))")
      case .search(let query):
        // The query is user input and is deliberately not echoed; the search
        // URL still shows which parameter carried it.
        let url = GoogleSearchEngine().searchURL(for: query)
        print("parsed-as-search \(URLLogSanitizer.sanitized(url))")
      case nil:
        print("parsed-as-empty")
      }
    }
    exit(0)
  }
}
