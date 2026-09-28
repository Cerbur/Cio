import Combine
import XCTest

private actor SuggestRequestLog {
  private(set) var requests: [(query: String, at: TimeInterval)] = []

  func append(_ query: String) {
    requests.append((query, ProcessInfo.processInfo.systemUptime))
  }
}

@MainActor
final class SpotlightAutocompleteTests: XCTestCase {
  private func makeHistory() throws -> HistoryService {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpotlightAutocompleteTests-\(UUID().uuidString)")
    let store = try HistoryStore(dataDirectory: directory)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return HistoryService(store: store)
  }

  func testHistoryMatchesURLHostAndTitleWithVisitsAndRecency() throws {
    let history = try makeHistory()
    let now = Date()
    let recent = URL(string: "https://swift.org/documentation")!
    let frequent = URL(string: "https://www.swift.org")!
    let titled = URL(string: "https://example.com")!
    history.recordVisit(url: recent, title: "Documentation", at: now)
    for day in 36...40 {
      history.recordVisit(url: frequent, title: "Swift", at: now.addingTimeInterval(-86_400 * Double(day)))
    }
    history.recordVisit(url: titled, title: "Swift language", at: now)

    let provider = HistorySuggestionProvider(history: history)
    let hostMatches = provider.suggestions(for: "swift", now: now)
    XCTAssertEqual(hostMatches.map(\.mode), [.website(recent), .website(frequent), .website(titled)])
    XCTAssertEqual(provider.suggestions(for: "documentation", now: now).first?.mode, .website(recent))
    XCTAssertEqual(provider.suggestions(for: "example.com", now: now).first?.mode, .website(titled))
  }

  func testMergeKeepsFourSectionsOrderedWithTwoPerProvider() {
    let root = URL(string: "https://example.com/")!
    let domain = SpotlightSuggestion(
      title: "example.com", subtitle: "", mode: .website(root), kind: .domainMatch, score: 90)
    let input = SpotlightSuggestion(
      title: "example", subtitle: "Search Google", mode: .googleSearch("example"), kind: .input, score: 100)
    let history = (0..<10).map { index in
      SpotlightSuggestion(
        title: "Example \(index)", subtitle: "https://example.com/\(index)",
        mode: .website(URL(string: "https://example.com/\(index)")!), kind: .historyAddress, score: 70 - index)
    }
    let online = (0..<10).map { index in
      SpotlightSuggestion(
        title: "example \(index)", subtitle: "Search Google",
        mode: .googleSearch("example \(index)"), kind: .onlineSearch, score: 70 - index)
    }
    let duplicate = SpotlightSuggestion(
      title: "Example root", subtitle: root.absoluteString,
      mode: .website(root), kind: .historyAddress, score: 80)

    let merged = SpotlightAutocompleteService.merge(
      domain: domain, input: input, history: [duplicate] + history, online: online)
    XCTAssertEqual(merged.first?.kind, .domainMatch)
    XCTAssertEqual(merged.dropFirst().first?.kind, .input)
    XCTAssertEqual(merged.count, 6)
    XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    XCTAssertEqual(merged.filter { $0.kind == .historyAddress }.count, 2)
    XCTAssertEqual(merged.filter { $0.kind == .onlineSearch }.count, 2)
    let firstOnline = merged.firstIndex { $0.kind == .onlineSearch }!
    XCTAssertTrue(merged[2..<firstOnline].allSatisfy { $0.kind == .historyAddress })
    XCTAssertEqual(
      SpotlightAutocompleteService.merge(domain: nil, input: input, history: history, online: online).first?.kind,
      .input)
  }

  func testImmediateTopRowsThenHistoryAt20msThenOnline() async throws {
    let history = try makeHistory()
    let page = URL(string: "https://swift.org/guide")!
    history.recordVisit(url: page, title: "Swift Guide", at: Date())
    let provider = SearchSuggestionProvider { request in
      try await Task.sleep(for: .milliseconds(140))
      let data = Data(#"["swift",["swift concurrency"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = SpotlightAutocompleteService(history: history, searchProvider: provider)
    var snapshots: [[SpotlightSuggestion]] = []
    let observation = service.$suggestions.dropFirst().sink { snapshots.append($0) }
    defer { observation.cancel() }

    service.update("swift")
    XCTAssertEqual(snapshots.count, 1)
    XCTAssertEqual(snapshots[0].map(\.kind), [.domainMatch, .input])
    XCTAssertEqual(snapshots[0][0].title, "swift.org")
    XCTAssertEqual(snapshots[0][0].subtitle, "")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(snapshots.count, 2)
    XCTAssertTrue(snapshots[1].contains { $0.mode == .website(page) })
    XCTAssertFalse(snapshots[1].contains { $0.mode == .googleSearch("swift concurrency") })
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(snapshots.count, 3)
    XCTAssertEqual(snapshots[2].last?.mode, .googleSearch("swift concurrency"))
  }

  func testFastOnlineResultMergesWithHistoryInOneLowerSectionUpdate() async throws {
    let history = try makeHistory()
    let page = URL(string: "https://swift.org/guide")!
    history.recordVisit(url: page, title: "Swift Guide", at: Date())
    let provider = SearchSuggestionProvider { request in
      let data = Data(#"["swift",["swift concurrency"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = SpotlightAutocompleteService(history: history, searchProvider: provider)
    var snapshots: [[SpotlightSuggestion]] = []
    let observation = service.$suggestions.dropFirst().sink { snapshots.append($0) }
    defer { observation.cancel() }

    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(snapshots.count, 2)
    XCTAssertEqual(snapshots[0].map(\.kind), [.domainMatch, .input])
    XCTAssertTrue(snapshots[1].contains { $0.mode == .website(page) })
    XCTAssertTrue(snapshots[1].contains { $0.mode == .googleSearch("swift concurrency") })
  }

  func testPrivateAndLocalInputsNeverReachSuggest() {
    for input in ["localhost", "localhost:8080", "http://router.local", "https://intranet.internal",
                  "192.168.1.1", "10.0.0.2/path", "http://[::1]/", "file:///tmp/secret",
                  "data:text/plain,secret", "about:blank", "open localhost now"] {
      XCTAssertFalse(SearchSuggestionProvider.maySend(input), input)
    }
    for input in ["swift concurrency", "example.com", "https://example.com/path"] {
      XCTAssertTrue(SearchSuggestionProvider.maySend(input), input)
    }
  }

  func testSearchProviderParsesGoogleResponseAndEncodesQuery() async throws {
    let provider = SearchSuggestionProvider { request in
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
      XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "swift async")
      let data = Data(#"["swift async",["swift async await","swift async let"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let result = try await provider.suggestions(for: "swift async")
    XCTAssertEqual(result.map(\.mode), [.googleSearch("swift async await"), .googleSearch("swift async let")])
  }

  func testFirstRequestIsImmediateAndLaterRequestsAreSpacedAndCoalesced() async throws {
    let log = SuggestRequestLog()
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      await log.append(query)
      try await Task.sleep(for: .milliseconds(200))
      let data = Data("[\"\(query)\",[]]".utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = SpotlightAutocompleteService(history: try makeHistory(), searchProvider: provider)
    service.update("first")
    try await Task.sleep(for: .milliseconds(10))
    let firstRequests = await log.requests
    XCTAssertEqual(firstRequests.map(\.query), ["first"])
    service.update("second")
    service.update("third")
    try await Task.sleep(for: .milliseconds(80))
    let requests = await log.requests
    XCTAssertEqual(requests.map(\.query), ["first", "third"])
    XCTAssertGreaterThanOrEqual(requests[1].at - requests[0].at, 0.025)
  }

  func testSlowOnlineResultIsNotDiscarded() async throws {
    let history = try makeHistory()
    history.recordVisit(url: URL(string: "https://swift.org")!, title: "Swift", at: Date())
    let provider = SearchSuggestionProvider { request in
      try await Task.sleep(for: .milliseconds(650))
      let data = Data(#"["swift",["swift concurrency"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = SpotlightAutocompleteService(history: history, searchProvider: provider)
    var snapshots: [[SpotlightSuggestion]] = []
    let observation = service.$suggestions.dropFirst().sink { snapshots.append($0) }
    defer { observation.cancel() }

    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertGreaterThanOrEqual(snapshots.count, 1)
    XCTAssertEqual(snapshots.first?.first?.mode, .website(URL(string: "https://swift.org/")!))
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertTrue(snapshots.last?.contains { $0.mode == .googleSearch("swift concurrency") } == true)
  }

  func testMatchingOnlineSuggestionsRemainWhileNextRequestRuns() async throws {
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      let data = Data("[\"\(query)\",[\"swift concurrency\"]]".utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = SpotlightAutocompleteService(history: try makeHistory(), searchProvider: provider)
    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(service.suggestions.contains { $0.mode == .googleSearch("swift concurrency") })
    service.update("swif")
    XCTAssertTrue(service.suggestions.contains { $0.mode == .googleSearch("swift concurrency") })
    service.update("other")
    XCTAssertFalse(service.suggestions.contains { $0.mode == .googleSearch("swift concurrency") })
  }

  func testNewInputReplacesInFlightAndStaleRemoteResults() async throws {
    let history = try makeHistory()
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      if query == "first" {
        // Simulate a transport that finishes even after cancellation.
        try? await Task.sleep(for: .milliseconds(280))
      }
      let data = Data("[\"\(query)\",[\"\(query) result\"]]".utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = SpotlightAutocompleteService(history: history, searchProvider: provider)
    service.update("first")
    try await Task.sleep(for: .milliseconds(150))
    service.update("second")
    XCTAssertEqual(service.suggestions.first?.mode, .googleSearch("second"))
    try await Task.sleep(for: .milliseconds(330))
    XCTAssertTrue(service.suggestions.contains { $0.mode == .googleSearch("second result") })
    XCTAssertFalse(service.suggestions.contains { $0.mode == .googleSearch("first result") })
  }
}
