import CioModel
import Foundation

@MainActor
public final class SearchSuggestionCache {
  static let shared = SearchSuggestionCache()

  private struct Entry {
    let suggestions: [NavigationSuggestion]
    let expiresAt: Date
    let storedAt: Date
  }

  private var entries: [String: Entry] = [:]
  private var retryAfter: Date?
  private var consecutiveFailures = 0
  private let capacity = 64
  private let lifetime: TimeInterval = 90
  private let failureCooldown: TimeInterval = 5

  func suggestions(for input: String, now: Date = Date()) -> [NavigationSuggestion]? {
    guard let entry = entries[input] else { return nil }
    guard entry.expiresAt > now else {
      entries.removeValue(forKey: input)
      return nil
    }
    return entry.suggestions
  }

  func store(_ suggestions: [NavigationSuggestion], for input: String, now: Date = Date()) {
    retryAfter = nil
    consecutiveFailures = 0
    entries[input] = Entry(
      suggestions: suggestions, expiresAt: now.addingTimeInterval(lifetime), storedAt: now)
    if entries.count > capacity,
       let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
      entries.removeValue(forKey: oldest)
    }
  }

  public func canRequest(now: Date = Date()) -> Bool {
    guard let retryAfter else { return true }
    if now >= retryAfter {
      self.retryAfter = nil
      consecutiveFailures = 0
      return true
    }
    return false
  }

  public func recordFailure(now: Date = Date()) {
    consecutiveFailures += 1
    if consecutiveFailures >= 2 {
      retryAfter = now.addingTimeInterval(failureCooldown)
    }
  }

  public init() {}
}

@MainActor
public struct SearchSuggestionProvider {
  let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let cache: SearchSuggestionCache

  public init(session: URLSession = .shared) {
    fetch = { request in try await session.data(for: request) }
    cache = .shared
  }

  public init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.fetch = fetch
    cache = SearchSuggestionCache()
  }

  func cachedSuggestions(for input: String) -> [NavigationSuggestion]? {
    cache.suggestions(for: input)
  }

  var canRequest: Bool { cache.canRequest() }

  public func suggestions(for input: String) async throws -> [NavigationSuggestion] {
    if let cached = cache.suggestions(for: input) { return cached }
    guard cache.canRequest() else { return [] }
    var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
    components.queryItems = [
      URLQueryItem(name: "client", value: "firefox"),
      URLQueryItem(name: "q", value: input),
    ]
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 5
    do {
      let (data, response) = try await fetch(request)
      try Task.checkCancellation()
      guard (response as? HTTPURLResponse)?.statusCode == 200,
            let payload = try JSONSerialization.jsonObject(with: data) as? [Any],
            payload.count > 1,
            let queries = payload[1] as? [String] else {
        throw URLError(.cannotParseResponse)
      }

      let suggestions: [NavigationSuggestion] = queries.prefix(10).enumerated().compactMap { index, query in
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return NavigationSuggestion(
          title: value,
          navigation: .search(value),
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

  public static func maySend(_ input: String) -> Bool {
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

