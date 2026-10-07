import Foundation

/// A navigation candidate, independent of any completion UI or tab action.
struct NavigationSuggestion: Identifiable, Equatable {
  enum Kind: Equatable {
    case domainMatch
    case input
    case historyAddress
    case onlineSearch
  }

  let title: String
  let navigation: NavigationInput
  let kind: Kind
  let score: Int

  var id: String { Self.id(for: navigation) }

  static func id(for navigation: NavigationInput) -> String {
    switch navigation {
    case .url(let url): "website:\(Self.urlKey(url))"
    case .search(let query): "search:\(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    }
  }

  static func urlKey(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.fragment = nil
    if components.path.isEmpty { components.path = "/" }
    return components.string ?? url.absoluteString
  }
}

/// Results and their input are published together. Consumers choose their own
/// ordering, row limits and presentation; provider groups may contain duplicates.
struct NavigationAutocompleteSnapshot: Equatable {
  let input: String
  let domain: NavigationSuggestion?
  let inputSuggestion: NavigationSuggestion?
  let history: [NavigationSuggestion]
  let online: [NavigationSuggestion]

  static let empty = NavigationAutocompleteSnapshot(
    input: "", domain: nil, inputSuggestion: nil, history: [], online: [])
}
