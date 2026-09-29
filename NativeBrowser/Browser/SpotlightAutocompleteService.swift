//
//  SpotlightAutocompleteService.swift
//  NativeBrowser
//
//  Keeps the immediate Spotlight rows responsive while slower providers fill in.
//

import Combine
import Foundation

struct SpotlightSuggestion: Identifiable, Equatable {
  enum Kind: Equatable {
    case domainMatch
    case input
    case historyAddress
    case onlineSearch
  }

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

  static func urlKey(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.fragment = nil
    if components.path.isEmpty { components.path = "/" }
    return components.string ?? url.absoluteString
  }
}

@MainActor
struct HistorySuggestionProvider {
  let history: HistoryService

  func domainSuggestion(for input: String, now: Date = Date()) -> SpotlightSuggestion? {
    var query = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    if query.hasPrefix("https://") { query.removeFirst(8) }
    else if query.hasPrefix("http://") { query.removeFirst(7) }
    if query.hasPrefix("www.") { query.removeFirst(4) }
    guard !query.isEmpty, !query.contains("/"), !query.contains(" ") else { return nil }

    let best = history.entries.compactMap { entry -> (HistoryEntry, String, Int)? in
      guard let host = entry.url.host else { return nil }
      let searchableHost = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
      let normalizedHost = searchableHost.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      guard normalizedHost.contains(query) else { return nil }
      let age = max(0, now.timeIntervalSince(entry.lastVisitedAt))
      let recency = age < 86_400 ? 20 : age < 604_800 ? 12 : age < 2_592_000 ? 6 : 0
      let match = normalizedHost.hasPrefix(query) ? 80 : 40
      return (entry, searchableHost, match + min(entry.visitCount, 10) * 2 + recency)
    }.max { $0.2 < $1.2 }
    guard let (entry, host, score) = best,
          var components = URLComponents(url: entry.url, resolvingAgainstBaseURL: false) else { return nil }
    components.path = "/"
    components.query = nil
    components.fragment = nil
    guard let origin = components.url else { return nil }
    return SpotlightSuggestion(
      title: host, subtitle: "", mode: .website(origin), kind: .domainMatch, score: score)
  }

  func suggestions(for input: String, now: Date = Date()) -> [SpotlightSuggestion] {
    let query = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    guard !query.isEmpty else { return [] }

    return history.entries.compactMap { entry in
      let url = entry.url.absoluteString
      let host = entry.url.host ?? ""
      let title = entry.title
      let normalizedURL = url.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      let normalizedHost = host.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      let searchableHost = normalizedHost.hasPrefix("www.") ? String(normalizedHost.dropFirst(4)) : normalizedHost
      let normalizedTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

      let matchScore: Int
      if searchableHost.hasPrefix(query) { matchScore = 80 }
      else if normalizedURL.hasPrefix(query) { matchScore = 75 }
      else if normalizedTitle.hasPrefix(query) { matchScore = 65 }
      else if searchableHost.contains(query) || normalizedURL.contains(query) { matchScore = 45 }
      else if normalizedTitle.contains(query) { matchScore = 35 }
      else { return nil }

      let visits = min(entry.visitCount, 20)
      let age = max(0, now.timeIntervalSince(entry.lastVisitedAt))
      let recency = age < 86_400 ? 20 : age < 604_800 ? 12 : age < 2_592_000 ? 6 : 0
      return SpotlightSuggestion(
        title: HistoryURLPolicy.usefulTitle(title) ?? host,
        subtitle: url,
        mode: .website(entry.url),
        kind: .historyAddress,
        score: matchScore + min(visits, 10) * 2 + recency)
    }.sorted { $0.score > $1.score }.prefix(10).map { $0 }
  }
}

@MainActor
final class SearchSuggestionCache {
  static let shared = SearchSuggestionCache()

  private struct Entry {
    let suggestions: [SpotlightSuggestion]
    let expiresAt: Date
    let storedAt: Date
  }

  private var entries: [String: Entry] = [:]
  private var retryAfter: Date?
  private var consecutiveFailures = 0
  private let capacity = 64
  private let lifetime: TimeInterval = 90
  private let failureCooldown: TimeInterval = 5

  func suggestions(for input: String, now: Date = Date()) -> [SpotlightSuggestion]? {
    guard let entry = entries[input] else { return nil }
    guard entry.expiresAt > now else {
      entries.removeValue(forKey: input)
      return nil
    }
    return entry.suggestions
  }

  func store(_ suggestions: [SpotlightSuggestion], for input: String, now: Date = Date()) {
    retryAfter = nil
    consecutiveFailures = 0
    entries[input] = Entry(
      suggestions: suggestions, expiresAt: now.addingTimeInterval(lifetime), storedAt: now)
    if entries.count > capacity,
       let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
      entries.removeValue(forKey: oldest)
    }
  }

  func canRequest(now: Date = Date()) -> Bool {
    guard let retryAfter else { return true }
    if now >= retryAfter {
      self.retryAfter = nil
      consecutiveFailures = 0
      return true
    }
    return false
  }

  func recordFailure(now: Date = Date()) {
    consecutiveFailures += 1
    if consecutiveFailures >= 2 {
      retryAfter = now.addingTimeInterval(failureCooldown)
    }
  }
}

@MainActor
struct SearchSuggestionProvider {
  let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let cache: SearchSuggestionCache

  init(session: URLSession = .shared) {
    fetch = { request in try await session.data(for: request) }
    cache = .shared
  }

  init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.fetch = fetch
    cache = SearchSuggestionCache()
  }

  func cachedSuggestions(for input: String) -> [SpotlightSuggestion]? {
    cache.suggestions(for: input)
  }

  var canRequest: Bool { cache.canRequest() }

  func suggestions(for input: String) async throws -> [SpotlightSuggestion] {
    if let cached = cache.suggestions(for: input) { return cached }
    guard cache.canRequest() else { return [] }
    var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
    components.queryItems = [
      URLQueryItem(name: "client", value: "firefox"),
      URLQueryItem(name: "q", value: input),
    ]
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 3
    do {
      let (data, response) = try await fetch(request)
      try Task.checkCancellation()
      guard (response as? HTTPURLResponse)?.statusCode == 200,
            let payload = try JSONSerialization.jsonObject(with: data) as? [Any],
            payload.count > 1,
            let queries = payload[1] as? [String] else {
        throw URLError(.cannotParseResponse)
      }

      let suggestions: [SpotlightSuggestion] = queries.prefix(10).enumerated().compactMap { index, query in
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return SpotlightSuggestion(
          title: value,
          subtitle: "Search Google",
          mode: .googleSearch(value),
          kind: .onlineSearch,
          score: 70 - index)
      }
      cache.store(suggestions, for: input)
      return suggestions
    } catch {
      if !Task.isCancelled { cache.recordFailure() }
      throw error
    }
  }

  static func maySend(_ input: String) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 200 else { return false }
    // Check each token as well as the full input, so a private address inside
    // a longer query is not inadvertently sent to Google.
    return trimmed.split(whereSeparator: \.isWhitespace).allSatisfy { token in
      let text = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "(),;\"'"))
      guard case .url(let url) = parseNavigationInput(text) else { return true }
      guard let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased() else { return false }
      if host == "localhost" || host.hasSuffix(".localhost") ||
          host.hasSuffix(".local") || host.hasSuffix(".internal") ||
          host.hasSuffix(".lan") || host.hasSuffix(".home") ||
          host.hasSuffix(".test") || !host.contains(".") || host.contains(":") {
        return false
      }
      // IP literals can refer to private networks. Avoid sending any literal.
      if host.split(separator: ".").count == 4 &&
          host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) {
        return false
      }
      return true
    }
  }
}

@MainActor
final class SpotlightAutocompleteService: ObservableObject {
  @Published private(set) var suggestions: [SpotlightSuggestion] = []

  private let historyProvider: HistorySuggestionProvider
  private let searchProvider: SearchSuggestionProvider
  private var remoteTask: Task<Void, Never>?
  private var historyTask: Task<Void, Never>?
  private var generation = 0
  private var lastRemoteRequestAt: TimeInterval?
  private var domainMatch: SpotlightSuggestion?
  private var inputSuggestion: SpotlightSuggestion?
  private var historyAddresses: [SpotlightSuggestion] = []
  private var onlineSuggestions: [SpotlightSuggestion] = []
  private(set) var requestedInput = ""
  private(set) var displayedInput = ""

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
      displayedInput = input
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
    displayedInput = input
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
    let merged = Self.merge(
      domain: domainMatch, input: inputSuggestion,
      history: historyAddresses, online: onlineSuggestions)
    if suggestions != merged { suggestions = merged }
  }

  private static func inputSuggestion(for input: String) -> SpotlightSuggestion? {
    guard let mode = SpotlightMode.suggestions(for: input).first else { return nil }
    return SpotlightSuggestion(
      title: mode.title, subtitle: mode.subtitle, mode: mode, kind: .input, score: 100)
  }

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
    for candidate in uniqueHistory.prefix(historyCount) { _ = append(candidate) }
    for candidate in uniqueOnline { _ = append(candidate) }
    return result
  }
}
