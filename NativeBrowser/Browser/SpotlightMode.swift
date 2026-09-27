//
//  SpotlightMode.swift
//  NativeBrowser
//
//  Each Spotlight capability supplies its own destination. The suggestion
//  builder chooses which modes apply to the current text; the view only renders
//  and selects them.
//

import Foundation

enum SpotlightMode: Equatable {
  case website(URL)
  case googleSearch(String)

  var destinationURL: URL {
    switch self {
    case .website(let url): url
    case .googleSearch(let query): GoogleSearchEngine().searchURL(for: query)
    }
  }

  var symbolName: String {
    switch self {
    case .website: "globe"
    case .googleSearch: "magnifyingglass"
    }
  }

  var title: String {
    switch self {
    case .website(let url): url.host ?? url.absoluteString
    case .googleSearch(let query): query
    }
  }

  var subtitle: String {
    switch self {
    case .website: "Open website"
    case .googleSearch: "Search Google"
    }
  }

  static func suggestions(for text: String) -> [SpotlightMode] {
    guard let input = parseNavigationInput(text) else { return [] }
    switch input {
    case .url(let url):
      return [.website(url), .googleSearch(text.trimmingCharacters(in: .whitespacesAndNewlines))]
    case .search(let query):
      return [.googleSearch(query)]
    }
    // TODO: Add a tab-search mode that searches tabs across every Space and
    // selects the matching tab when the user presses Return.
  }
}
