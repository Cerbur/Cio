@testable import CioEngine
import XCTest

private actor AddressRequestLog {
  private(set) var queries: [String] = []
  func append(_ query: String) { queries.append(query) }
}

@MainActor
final class AddressAutocompleteTests: XCTestCase {
  private func makeHistory() throws -> HistoryService {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AddressAutocompleteTests-\(UUID().uuidString)")
    let store = try HistoryStore(dataDirectory: directory)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return HistoryService(store: store)
  }

  func testFiveRowsAndCandidatePreviewDoNotRequestAgain() async throws {
    let log = AddressRequestLog()
    let history = try makeHistory()
    for index in 0..<8 {
      history.recordVisit(url: URL(string: "https://swift.org/guide/\(index)")!,
                          title: "Swift guide \(index)", at: Date())
    }
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      await log.append(query)
      let data = Data(#"["swift",["swift concurrency","swift docs","swift examples"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let model = AddressAutocompleteModel(history: history, searchProvider: provider)
    model.begin("")
    model.edit("swift", isComposing: false, allowsCompletion: true)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(model.suggestions.count, 5)
    XCTAssertTrue(model.suggestions.contains { $0.kind == .onlineSearch })
    XCTAssertEqual(model.input.text, "swift.org")
    XCTAssertEqual(model.input.selection, NSRange(location: 5, length: 4))
    model.select(4)
    let selected = model.selectedMode
    let rows = model.suggestions
    model.acceptCompletion()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(model.input.userInput, "swift")
    XCTAssertEqual(model.suggestions, rows)
    XCTAssertEqual(model.selectedMode, selected)
    let queries = await log.queries
    XCTAssertEqual(queries, ["swift"])
    model.move(1)
    XCTAssertEqual(model.selectedIndex, 0)
    model.move(-1)
    XCTAssertEqual(model.selectedIndex, 4)
  }

  func testFocusKeepsCapsuleUntilTextChanges() async throws {
    let log = AddressRequestLog()
    let history = try makeHistory()
    history.recordVisit(url: URL(string: "https://example.com/previous")!, title: "Example", at: Date())
    let provider = SearchSuggestionProvider { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems!.first(where: { $0.name == "q" })!.value!
      await log.append(query)
      let data = Data(#"["example",["example search"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let model = AddressAutocompleteModel(history: history, searchProvider: provider)
    for text in ["https://unvisited.test/", "https://example.com/", "example", ""] {
      model.begin(text)
      model.edit(text, isComposing: false, allowsCompletion: false)
      model.move(1)
      try await Task.sleep(for: .milliseconds(80))
      XCTAssertTrue(model.isActive)
      XCTAssertFalse(model.hasUserEdited)
      XCTAssertTrue(model.suggestions.isEmpty, "Focus must not retrieve candidates for \(text)")
      XCTAssertEqual(model.input.text, text)
      XCTAssertNil(model.selectedMode)
      model.end()
    }
    let queries = await log.queries
    XCTAssertTrue(queries.isEmpty, "Focus must not send a search query")
    model.begin("https://example.com/")
    model.edit("example", isComposing: false, allowsCompletion: true)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertFalse(model.suggestions.isEmpty)
    XCTAssertTrue(model.hasUserEdited)
    XCTAssertNotNil(model.selectedMode)
    model.end()
    model.begin("https://example.com/")
    XCTAssertTrue(model.suggestions.isEmpty)
    XCTAssertEqual(model.input.text, "https://example.com/")
    XCTAssertNil(model.selectedMode)
  }

  func testReopeningRequiresAnotherEditToRetrieveCandidates() throws {
    let model = AddressAutocompleteModel(history: try makeHistory())
    model.begin("")
    model.edit("localhost", isComposing: false, allowsCompletion: false)
    XCTAssertEqual(model.suggestions.count, 1)
    model.end()
    XCTAssertTrue(model.suggestions.isEmpty)
    XCTAssertNil(model.selectedMode)
    model.begin("localhost")
    XCTAssertTrue(model.suggestions.isEmpty)
    XCTAssertNil(model.selectedMode)
    model.edit("localhost:8080", isComposing: false, allowsCompletion: false)
    XCTAssertEqual(model.suggestions.count, 1)
    XCTAssertNotNil(model.selectedMode)
  }

  func testCompositionAndDismissalRejectLateResults() async throws {
    let provider = SearchSuggestionProvider { request in
      try await Task.sleep(for: .milliseconds(80))
      let data = Data(#"["swift",["swift guide"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let model = AddressAutocompleteModel(history: try makeHistory(), searchProvider: provider)
    model.begin("")
    model.edit("swift", isComposing: false, allowsCompletion: true)
    model.edit("中", isComposing: true, allowsCompletion: false)
    model.move(1)
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertTrue(model.suggestions.isEmpty)
    XCTAssertEqual(model.input.text, "中")
    XCTAssertNil(model.selectedMode)
    model.edit("swift", isComposing: false, allowsCompletion: false)
    model.end()
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertTrue(model.suggestions.isEmpty)
    XCTAssertFalse(model.isActive)
  }

  func testSelectedCandidateTracksPreviewAndDeletingSuffixIsAnEdit() async throws {
    let history = try makeHistory()
    history.recordVisit(url: URL(string: "https://example.test/guide")!, title: "Example guide", at: Date())
    let model = AddressAutocompleteModel(history: history)
    model.begin("")
    model.edit("example.test", isComposing: false, allowsCompletion: true)
    try await Task.sleep(for: .milliseconds(80))
    let historyIndex = try XCTUnwrap(model.suggestions.firstIndex { $0.kind == .historyAddress })
    model.select(historyIndex)
    XCTAssertEqual(model.selectedSuggestion, model.suggestions[historyIndex])
    XCTAssertEqual(model.selectedMode, .website(URL(string: "https://example.test/guide")!))
    XCTAssertEqual(model.input.text, "example.test/guide")
    XCTAssertEqual(model.input.userInput, "example.test")
    model.edit("example.test", isComposing: false, allowsCompletion: false)
    XCTAssertEqual(model.input.text, "example.test", "Deleting the preview suffix must not reinsert it")
    XCTAssertEqual(model.selectedIndex, 0)
    model.edit("example", isComposing: false, allowsCompletion: true)
    let searchIndex = try XCTUnwrap(model.suggestions.firstIndex { $0.mode == .googleSearch("example") })
    model.select(searchIndex)
    XCTAssertEqual(model.selectedSuggestion?.symbolName, "magnifyingglass")
    XCTAssertEqual(model.input.text, "example")
    model.move(-1)
    XCTAssertEqual(model.selectedSuggestion?.symbolName, "globe")
    XCTAssertEqual(model.input.text, "example.test")
    model.end()
    XCTAssertNil(model.selectedSuggestion)
  }

  func testRefocusRejectsResultsFromPreviousEdit() async throws {
    let provider = SearchSuggestionProvider { request in
      try await Task.sleep(for: .milliseconds(80))
      let data = Data(#"["swift",["swift guide"]]"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let model = AddressAutocompleteModel(history: try makeHistory(), searchProvider: provider)
    model.begin("")
    model.edit("swift", isComposing: false, allowsCompletion: true)
    model.end()
    model.edit("ignored", isComposing: false, allowsCompletion: true)
    model.begin("swift")
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertTrue(model.suggestions.isEmpty)
    XCTAssertNil(model.selectedSuggestion)
    XCTAssertEqual(model.input.text, "swift")
    XCTAssertFalse(model.hasUserEdited)
  }
}
