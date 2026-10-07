import Combine
import XCTest

@MainActor
final class SpotlightAutocompleteTests: XCTestCase {
  private func makeHistory() throws -> HistoryService {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpotlightAutocompleteTests-\(UUID().uuidString)")
    let store = try HistoryStore(dataDirectory: directory)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return HistoryService(store: store)
  }

  func testMergeFillsAvailableRowsWithBothProviders() {
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
    XCTAssertEqual(merged.count, 10)
    XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    XCTAssertEqual(merged.filter { $0.kind == .historyAddress }.count, 4)
    XCTAssertEqual(merged.filter { $0.kind == .onlineSearch }.count, 4)
    let firstOnline = merged.firstIndex { $0.kind == .onlineSearch }!
    XCTAssertTrue(merged[2..<firstOnline].allSatisfy { $0.kind == .historyAddress })
    XCTAssertLessThan(firstOnline, 5)
    XCTAssertEqual(
      SpotlightAutocompleteService.merge(domain: nil, input: input, history: history, online: online).first?.kind,
      .input)
    XCTAssertEqual(
      SpotlightAutocompleteService.merge(domain: domain, input: input, history: history, online: []).count,
      10)
    XCTAssertEqual(
      SpotlightAutocompleteService.merge(domain: domain, input: input, history: [], online: online).count,
      10)
  }

  func testImmediateTopRowsThenHistoryThenOnline() async throws {
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

  func testFastOnlineResultAndHistoryBothPublish() async throws {
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
    XCTAssertGreaterThanOrEqual(snapshots.count, 2)
    XCTAssertEqual(snapshots[0].map(\.kind), [.domainMatch, .input])
    XCTAssertTrue(snapshots.last?.contains { $0.mode == .website(page) } == true)
    XCTAssertTrue(snapshots.last?.contains { $0.mode == .googleSearch("swift concurrency") } == true)
  }

}
