import Foundation

@MainActor
struct HistorySuggestionProvider {
  let history: HistoryService

  func domainSuggestion(for input: String, now: Date = Date()) -> NavigationSuggestion? {
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
    return NavigationSuggestion(
      title: host, navigation: .url(origin), kind: .domainMatch, score: score)
  }

  func suggestions(for input: String, now: Date = Date()) -> [NavigationSuggestion] {
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
      return NavigationSuggestion(
        title: HistoryURLPolicy.usefulTitle(title) ?? host,
        navigation: .url(entry.url),
        kind: .historyAddress,
        score: matchScore + min(visits, 10) * 2 + recency)
    }.sorted { $0.score > $1.score }.prefix(10).map { $0 }
  }
}

