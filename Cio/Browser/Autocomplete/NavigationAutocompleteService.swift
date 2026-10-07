import CioModel
import Combine
import Foundation

/// One instance per input surface. History and the search cache can be shared,
/// while in-flight work, input and cancellation belong to this instance.
@MainActor
final class NavigationAutocompleteService: ObservableObject {
  @Published private(set) var snapshot: NavigationAutocompleteSnapshot = .empty

  private let historyProvider: HistorySuggestionProvider
  private let searchProvider: SearchSuggestionProvider
  private var remoteTask: Task<Void, Never>?
  private var historyTask: Task<Void, Never>?
  private var generation = 0
  private var lastRemoteRequestAt: TimeInterval?
  private var domainMatch: NavigationSuggestion?
  private var inputSuggestion: NavigationSuggestion?
  private var historyAddresses: [NavigationSuggestion] = []
  private var onlineSuggestions: [NavigationSuggestion] = []
  private(set) var requestedInput = ""

  init(history: HistoryService, searchProvider: SearchSuggestionProvider = .init()) {
    historyProvider = HistorySuggestionProvider(history: history)
    self.searchProvider = searchProvider
  }

  func update(_ text: String) {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if input == requestedInput && (remoteTask != nil || historyTask != nil) { return }
    remoteTask?.cancel()
    historyTask?.cancel()
    remoteTask = nil
    historyTask = nil
    generation += 1
    let currentGeneration = generation
    requestedInput = input
    guard !input.isEmpty else {
      domainMatch = nil
      inputSuggestion = nil
      historyAddresses = []
      onlineSuggestions = []
      lastRemoteRequestAt = nil
      publish()
      return
    }

    domainMatch = historyProvider.domainSuggestion(for: input)
    inputSuggestion = Self.inputSuggestion(for: input)
    historyAddresses = []
    let normalizedInput = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let maySend = SearchSuggestionProvider.maySend(input)
    let cachedOnline = maySend ? searchProvider.cachedSuggestions(for: input) : nil
    onlineSuggestions = cachedOnline ?? (maySend
      ? onlineSuggestions.filter {
        $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
          .hasPrefix(normalizedInput)
      }
      : [])
    publish()

    historyTask = Task { [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
      let matches = self.historyProvider.suggestions(for: input)
      guard !Task.isCancelled, self.generation == currentGeneration else { return }
      self.historyAddresses = matches
      self.publish()
      self.historyTask = nil
    }

    guard maySend, cachedOnline == nil, searchProvider.canRequest else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let delay = max(0, (lastRemoteRequestAt ?? 0) + 0.04 - now)
    remoteTask = Task { [weak self, searchProvider] in
      do {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
        self.lastRemoteRequestAt = ProcessInfo.processInfo.systemUptime
        let remote = try await searchProvider.suggestions(for: input)
        guard !Task.isCancelled, self.generation == currentGeneration else { return }
        self.onlineSuggestions = remote
        self.publish()
        self.remoteTask = nil
      } catch {
        // History remains available when the remote provider is unavailable.
        if let self, self.generation == currentGeneration { self.remoteTask = nil }
      }
    }
  }

  func cancel() {
    remoteTask?.cancel()
    historyTask?.cancel()
    remoteTask = nil
    historyTask = nil
    lastRemoteRequestAt = nil
    generation += 1
  }

  private func publish() {
    let next = NavigationAutocompleteSnapshot(
      input: requestedInput, domain: domainMatch, inputSuggestion: inputSuggestion,
      history: historyAddresses, online: onlineSuggestions)
    if snapshot != next { snapshot = next }
  }

  private static func inputSuggestion(for input: String) -> NavigationSuggestion? {
    guard let navigation = parseNavigationInput(input) else { return nil }
    let title: String
    switch navigation {
    case .url(let url): title = url.host ?? url.absoluteString
    case .search(let query): title = query
    }
    return NavigationSuggestion(title: title, navigation: navigation, kind: .input, score: 100)
  }
}
