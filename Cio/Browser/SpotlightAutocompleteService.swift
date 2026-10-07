// Spotlight's presentation adapter. Retrieval and request state live in the
// reusable NavigationAutocompleteService; row formatting and ordering stay here.

import Combine
import Foundation

struct SpotlightSuggestion: Identifiable, Equatable {
  typealias Kind = NavigationSuggestion.Kind

  let title: String
  let subtitle: String
  let mode: SpotlightMode
  let kind: Kind
  let score: Int

  var action: SpotlightAction { mode.action }

  var id: String {
    switch mode {
    case .website(let url): "website:\(Self.urlKey(url))"
    case .googleSearch(let query): "search:\(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    }
  }

  var symbolName: String { mode.symbolName }

  static func urlKey(_ url: URL) -> String { NavigationSuggestion.urlKey(url) }

  init(title: String, subtitle: String, mode: SpotlightMode, kind: Kind, score: Int) {
    self.title = title
    self.subtitle = subtitle
    self.mode = mode
    self.kind = kind
    self.score = score
  }

  init(_ suggestion: NavigationSuggestion) {
    let mode: SpotlightMode
    switch suggestion.navigation {
    case .url(let url): mode = .website(url)
    case .search(let query): mode = .googleSearch(query)
    }
    let subtitle: String
    switch suggestion.kind {
    case .domainMatch: subtitle = ""
    case .input, .onlineSearch: subtitle = mode.subtitle
    case .historyAddress:
      if case .url(let url) = suggestion.navigation { subtitle = url.absoluteString }
      else { subtitle = mode.subtitle }
    }
    self.init(
      title: suggestion.title, subtitle: subtitle, mode: mode,
      kind: suggestion.kind, score: suggestion.score)
  }
}

@MainActor
final class SpotlightAutocompleteService: ObservableObject {
  @Published private(set) var suggestions: [SpotlightSuggestion] = []
  private(set) var displayedInput = ""
  var requestedInput: String { autocomplete.requestedInput }

  private let autocomplete: NavigationAutocompleteService
  private var observation: AnyCancellable?

  init(history: HistoryService, searchProvider: SearchSuggestionProvider = .init()) {
    autocomplete = NavigationAutocompleteService(history: history, searchProvider: searchProvider)
    observation = autocomplete.$snapshot.sink { [weak self] snapshot in
      guard let self else { return }
      self.displayedInput = snapshot.input
      let merged = Self.merge(
        domain: snapshot.domain.map(SpotlightSuggestion.init),
        input: snapshot.inputSuggestion.map(SpotlightSuggestion.init),
        history: snapshot.history.map(SpotlightSuggestion.init),
        online: snapshot.online.map(SpotlightSuggestion.init))
      if self.suggestions != merged { self.suggestions = merged }
    }
  }

  func update(_ text: String) { autocomplete.update(text) }

  func cancel() { autocomplete.cancel() }

  static func merge(
    domain: SpotlightSuggestion?, input: SpotlightSuggestion?,
    history: [SpotlightSuggestion], online: [SpotlightSuggestion]
  ) -> [SpotlightSuggestion] {
    var seen = Set<String>()
    var result: [SpotlightSuggestion] = []
    func append(_ candidate: SpotlightSuggestion) -> Bool {
      guard result.count < 10, seen.insert(candidate.id).inserted else { return false }
      result.append(candidate)
      return true
    }
    if let domain { _ = append(domain) }
    if let input { _ = append(input) }

    let baseSeen = seen
    var historySeen = baseSeen
    let uniqueHistory = history.filter { historySeen.insert($0.id).inserted }
    var onlineSeen = baseSeen
    let uniqueOnline = online.filter { onlineSeen.insert($0.id).inserted }
    let slots = 10 - result.count
    let historyCount = min(uniqueHistory.count, max(slots / 2, slots - uniqueOnline.count))
    let earlyHistoryCount = min(2, historyCount)
    for candidate in uniqueHistory.prefix(earlyHistoryCount) { _ = append(candidate) }
    // Spotlight shows five rows before scrolling. Keep one online result in
    // that first group even when history has enough matches to fill ten rows.
    if let firstOnline = uniqueOnline.first { _ = append(firstOnline) }
    for candidate in uniqueHistory.dropFirst(earlyHistoryCount).prefix(historyCount - earlyHistoryCount) {
      _ = append(candidate)
    }
    for candidate in uniqueOnline.dropFirst() { _ = append(candidate) }
    return result
  }
}
