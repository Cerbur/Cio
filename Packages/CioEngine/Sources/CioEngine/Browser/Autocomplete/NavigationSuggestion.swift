import CioModel
import Foundation

/// A navigation candidate, independent of any completion UI or tab action.
public struct NavigationSuggestion: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case domainMatch
    case input
    case historyAddress
    case onlineSearch
  }

  public let title: String
  public let navigation: NavigationInput
  public let kind: Kind
  public let score: Int

  public var id: String { Self.id(for: navigation) }

  public static func id(for navigation: NavigationInput) -> String {
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

  public init(
    title: String,
    navigation: NavigationInput,
    kind: Kind,
    score: Int
  ) {
    self.title = title
    self.navigation = navigation
    self.kind = kind
    self.score = score
  }
}

/// Results and their input are published together. Consumers choose their own
/// ordering, row limits and presentation; provider groups may contain duplicates.
public struct NavigationAutocompleteSnapshot: Equatable, Sendable {
  public let input: String
  public let domain: NavigationSuggestion?
  public let inputSuggestion: NavigationSuggestion?
  public let history: [NavigationSuggestion]
  public let online: [NavigationSuggestion]

  public static let empty = NavigationAutocompleteSnapshot(
    input: "", domain: nil, inputSuggestion: nil, history: [], online: [])

  public init(
    input: String,
    domain: NavigationSuggestion?,
    inputSuggestion: NavigationSuggestion?,
    history: [NavigationSuggestion],
    online: [NavigationSuggestion]
  ) {
    self.input = input
    self.domain = domain
    self.inputSuggestion = inputSuggestion
    self.history = history
    self.online = online
  }
}
