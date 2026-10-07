import Combine
import XCTest

private actor SuggestRequestLog {
  private(set) var requests: [(query: String, at: TimeInterval)] = []

  func append(_ query: String) {
    requests.append((query, ProcessInfo.processInfo.systemUptime))
  }
}

@MainActor
final class NavigationAutocompleteTests: XCTestCase {
  private func makeHistory() throws -> HistoryService {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NavigationAutocompleteTests-\(UUID().uuidString)")
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
    XCTAssertEqual(hostMatches.map(\.navigation), [.url(recent), .url(frequent), .url(titled)])
    XCTAssertEqual(provider.suggestions(for: "documentation", now: now).first?.navigation, .url(recent))
    XCTAssertEqual(provider.suggestions(for: "example.com", now: now).first?.navigation, .url(titled))
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
      XCTAssertGreaterThanOrEqual(request.timeoutInterval, 5)
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
      XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "swift async")
      let data = Data(#"["swift async",["swift async await","swift async let"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let result = try await provider.suggestions(for: "swift async")
    XCTAssertEqual(result.map(\.navigation), [.search("swift async await"), .search("swift async let")])
  }

  func testReturningToQueryUsesCachedRemoteResults() async throws {
    let log = SuggestRequestLog()
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      await log.append(query)
      let data = Data("[\"\(query)\",[\"\(query) result\"]]".utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = NavigationAutocompleteService(history: try makeHistory(), searchProvider: provider)
    service.update("swift")
    try await Task.sleep(for: .milliseconds(60))
    service.update("other")
    try await Task.sleep(for: .milliseconds(60))
    service.update("swift")
    XCTAssertTrue(service.snapshot.candidates.contains { $0.navigation == .search("swift result") })
    try await Task.sleep(for: .milliseconds(60))
    let requests = await log.requests
    XCTAssertEqual(requests.map(\.query), ["swift", "other"])
    XCTAssertTrue(service.snapshot.candidates.contains { $0.navigation == .search("swift result") })
  }

  func testRepeatedRemoteFailureKeepsLocalSuggestionsAndTemporarilyStopsRequests() async throws {
    let history = try makeHistory()
    let page = URL(string: "https://swift.org/guide")!
    history.recordVisit(url: page, title: "Swift Guide", at: Date())
    let log = SuggestRequestLog()
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      await log.append(query)
      throw URLError(.timedOut)
    }
    let service = NavigationAutocompleteService(history: history, searchProvider: provider)
    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(service.snapshot.candidates.contains { $0.navigation == .url(page) })
    service.update("swift guide")
    try await Task.sleep(for: .milliseconds(70))
    service.update("swift guide examples")
    try await Task.sleep(for: .milliseconds(70))
    let requests = await log.requests
    XCTAssertEqual(requests.map(\.query), ["swift", "swift guide"])
    XCTAssertEqual(service.snapshot.candidates.first?.navigation, .search("swift guide examples"))
  }

  func testMatchingOnlineSuggestionsSurviveFailureCooldown() async throws {
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      if query == "swift" {
        let data = Data(#"["swift",["swift apple"]]"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      }
      throw URLError(.timedOut)
    }
    let service = NavigationAutocompleteService(history: try makeHistory(), searchProvider: provider)
    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    service.update("swift a")
    try await Task.sleep(for: .milliseconds(50))
    service.update("swift ap")
    try await Task.sleep(for: .milliseconds(50))
    service.update("swift app")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(service.snapshot.candidates.contains {
      $0.kind == .onlineSearch && $0.navigation == .search("swift apple")
    })
  }

  func testFailureCooldownExpires() {
    let cache = SearchSuggestionCache()
    let now = Date()
    cache.recordFailure(now: now)
    XCTAssertTrue(cache.canRequest(now: now))
    cache.recordFailure(now: now)
    XCTAssertFalse(cache.canRequest(now: now.addingTimeInterval(4)))
    XCTAssertTrue(cache.canRequest(now: now.addingTimeInterval(5)))
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
    let service = NavigationAutocompleteService(history: try makeHistory(), searchProvider: provider)
    service.update("first")
    let firstDeadline = Date().addingTimeInterval(2)
    while await log.requests.isEmpty, Date() < firstDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let firstRequests = await log.requests
    XCTAssertEqual(firstRequests.map(\.query), ["first"])
    service.update("second")
    service.update("third")
    let nextDeadline = Date().addingTimeInterval(2)
    while await log.requests.count < 2, Date() < nextDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let requests = await log.requests
    XCTAssertEqual(requests.map(\.query), ["first", "third"])
    guard requests.count == 2 else { return }
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
    let service = NavigationAutocompleteService(history: history, searchProvider: provider)
    var snapshots: [[NavigationSuggestion]] = []
    let observation = service.$snapshot.dropFirst().sink { snapshots.append($0.candidates) }
    defer { observation.cancel() }

    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertGreaterThanOrEqual(snapshots.count, 1)
    XCTAssertEqual(snapshots.first?.first?.navigation, .url(URL(string: "https://swift.org/")!))
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertTrue(snapshots.last?.contains { $0.navigation == .search("swift concurrency") } == true)
  }

  func testMatchingOnlineSuggestionsRemainWhileNextRequestRuns() async throws {
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      let data = Data("[\"\(query)\",[\"swift concurrency\"]]".utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = NavigationAutocompleteService(history: try makeHistory(), searchProvider: provider)
    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(service.snapshot.candidates.contains { $0.navigation == .search("swift concurrency") })
    service.update("swif")
    XCTAssertTrue(service.snapshot.candidates.contains { $0.navigation == .search("swift concurrency") })
    service.update("other")
    XCTAssertFalse(service.snapshot.candidates.contains { $0.navigation == .search("swift concurrency") })
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
    let service = NavigationAutocompleteService(history: history, searchProvider: provider)
    service.update("first")
    try await Task.sleep(for: .milliseconds(150))
    service.update("second")
    XCTAssertEqual(service.snapshot.candidates.first?.navigation, .search("second"))
    try await Task.sleep(for: .milliseconds(330))
    XCTAssertTrue(service.snapshot.candidates.contains { $0.navigation == .search("second result") })
    XCTAssertFalse(service.snapshot.candidates.contains { $0.navigation == .search("first result") })
  }

  func testIndependentInputsShareCacheWithoutSharingCancellation() async throws {
    let log = SuggestRequestLog()
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      await log.append(query)
      try await Task.sleep(for: .milliseconds(80))
      let data = Data("[\"\(query)\",[\"\(query) result\"]]".utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let history = try makeHistory()
    let spotlight = NavigationAutocompleteService(history: history, searchProvider: provider)
    let addressBar = NavigationAutocompleteService(history: history, searchProvider: provider)

    spotlight.update("swift")
    addressBar.update("browser")
    try await Task.sleep(for: .milliseconds(20))
    spotlight.cancel()
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(spotlight.snapshot.input, "swift")
    XCTAssertTrue(spotlight.snapshot.online.isEmpty)
    XCTAssertEqual(addressBar.snapshot.input, "browser")
    XCTAssertEqual(addressBar.snapshot.online.map(\.navigation), [.search("browser result")])

    spotlight.update("browser")
    XCTAssertEqual(spotlight.snapshot.online, addressBar.snapshot.online)
    try await Task.sleep(for: .milliseconds(20))
    let requests = await log.requests
    XCTAssertEqual(Set(requests.map(\.query)), Set(["swift", "browser"]))
    XCTAssertEqual(requests.count, 2)
  }

  func testClearingInputPreventsLateResultsFromReappearing() async throws {
    let log = SuggestRequestLog()
    let provider = SearchSuggestionProvider { request in
      await log.append("swift")
      try? await Task.sleep(for: .milliseconds(100))
      let data = Data(#"["swift",["swift concurrency"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = NavigationAutocompleteService(history: try makeHistory(), searchProvider: provider)
    service.update("  swift  ")
    XCTAssertEqual(service.snapshot.input, "swift")
    XCTAssertEqual(service.snapshot.inputSuggestion?.navigation, .search("swift"))
    try await Task.sleep(for: .milliseconds(20))
    let requests = await log.requests
    XCTAssertEqual(requests.count, 1)
    service.update(" ")
    XCTAssertEqual(service.snapshot, .empty)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(service.snapshot, .empty)
  }

  func testSnapshotKeepsProviderGroupsAvailableForIndependentPresentation() async throws {
    let history = try makeHistory()
    let root = URL(string: "https://swift.org/")!
    history.recordVisit(url: root, title: "Swift", at: Date())
    let provider = SearchSuggestionProvider { request in
      let data = Data(#"["swift",["swift concurrency"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = NavigationAutocompleteService(history: history, searchProvider: provider)
    service.update("swift")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(service.snapshot.domain?.navigation, .url(root))
    XCTAssertEqual(service.snapshot.inputSuggestion?.navigation, .search("swift"))
    XCTAssertEqual(service.snapshot.history.map(\.navigation), [.url(root)])
    XCTAssertEqual(service.snapshot.online.map(\.navigation), [.search("swift concurrency")])
    XCTAssertEqual(service.snapshot.domain?.id, service.snapshot.history.first?.id)
  }
}

private extension NavigationAutocompleteSnapshot {
  var candidates: [NavigationSuggestion] {
    [domain, inputSuggestion].compactMap { $0 } + history + online
  }
}
