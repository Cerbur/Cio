//
//  HistoryStoreTests.swift
//  NativeBrowserTests
//
//  CEF-free tests for SQLite history semantics and isolation.
//

import XCTest

final class HistoryStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeBrowserHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory {
      try? FileManager.default.removeItem(at: directory)
    }
    try super.tearDownWithError()
  }

  private func makeStore() throws -> HistoryStore {
    try HistoryStore(dataDirectory: directory)
  }

  private func url(_ value: String) -> URL { URL(string: value)! }

  func testEmptyHistoryStoreStartsEmpty() throws {
    let store = try makeStore()
    XCTAssertEqual(try store.loadRecent(), [])
    XCTAssertEqual(store.userVersion, 1)
    XCTAssertEqual(store.databaseURL.lastPathComponent, "history.sqlite3")
  }

  func testFirstVisitCreatesEntry() throws {
    let store = try makeStore()
    let date = Date(timeIntervalSince1970: 100)
    let entry = try store.recordVisit(url: url("https://example.com/page"), title: "Example", at: date)
    XCTAssertEqual(entry.title, "Example")
    XCTAssertEqual(entry.visitCount, 1)
    XCTAssertEqual(entry.firstVisitedAt, date)
    XCTAssertEqual(entry.lastVisitedAt, date)
  }

  func testSecondVisitSameExactURLIncrementsWithoutChangingFirstDate() throws {
    let store = try makeStore()
    let page = url("https://example.com/page")
    let first = try store.recordVisit(url: page, title: "First", at: Date(timeIntervalSince1970: 100))
    let second = try store.recordVisit(url: page, title: "Second", at: Date(timeIntervalSince1970: 200))
    XCTAssertEqual(second.visitCount, 2)
    XCTAssertEqual(second.firstVisitedAt, first.firstVisitedAt)
    XCTAssertEqual(second.lastVisitedAt.timeIntervalSince1970, 200)
    XCTAssertEqual(second.title, "Second")
  }

  func testTitleUpdateDoesNotIncrementVisitCount() throws {
    let store = try makeStore()
    let page = url("https://example.com/title")
    _ = try store.recordVisit(url: page, title: "Before", at: Date(timeIntervalSince1970: 100))
    try store.updateTitle(for: page, title: "After")
    let entry = try XCTUnwrap(try store.loadRecent().first)
    XCTAssertEqual(entry.title, "After")
    XCTAssertEqual(entry.visitCount, 1)
  }

  func testEmptyTitleDoesNotEraseUsefulTitle() throws {
    let store = try makeStore()
    let page = url("https://example.com/title")
    _ = try store.recordVisit(url: page, title: "Useful", at: Date(timeIntervalSince1970: 100))
    _ = try store.recordVisit(url: page, title: "   ", at: Date(timeIntervalSince1970: 200))
    let entry = try XCTUnwrap(try store.loadRecent().first)
    XCTAssertEqual(entry.title, "Useful")
    XCTAssertEqual(entry.visitCount, 2)
  }

  func testNewestFirstOrdering() throws {
    let store = try makeStore()
    _ = try store.recordVisit(url: url("https://example.com/old"), title: "Old", at: Date(timeIntervalSince1970: 100))
    _ = try store.recordVisit(url: url("https://example.com/new"), title: "New", at: Date(timeIntervalSince1970: 200))
    let entries = try store.loadRecent()
    XCTAssertEqual(entries.map { $0.url.absoluteString }, [
      "https://example.com/new", "https://example.com/old"
    ])
  }

  func testDistinctURLsRemainDistinct() throws {
    let store = try makeStore()
    _ = try store.recordVisit(url: url("https://example.com/page?a=1"), title: "A", at: Date(timeIntervalSince1970: 100))
    _ = try store.recordVisit(url: url("https://example.com/page?a=2"), title: "B", at: Date(timeIntervalSince1970: 200))
    XCTAssertEqual(try store.loadRecent().count, 2)
  }

  func testExactQueryAndFragmentArePersisted() throws {
    let store = try makeStore()
    let page = url("http://127.0.0.1:43123/page?code=fake-code-123#fragment-fake")
    _ = try store.recordVisit(url: page, title: "Fixture", at: Date(timeIntervalSince1970: 100))
    let restored = try XCTUnwrap(try store.loadRecent().first)
    XCTAssertEqual(restored.url.absoluteString, page.absoluteString)
    XCTAssertEqual(restored.url.query, "code=fake-code-123")
    XCTAssertEqual(restored.url.fragment, "fragment-fake")
  }

  func testClearRemovesAllEntries() throws {
    let store = try makeStore()
    _ = try store.recordVisit(url: url("https://example.com/one"), title: "One")
    _ = try store.recordVisit(url: url("https://example.com/two"), title: "Two")
    try store.clear()
    XCTAssertTrue(try store.loadRecent().isEmpty)
  }

  func testDatabaseSurvivesReopeningHistoryStore() throws {
    let page = url("https://example.com/persist")
    do {
      let store = try makeStore()
      _ = try store.recordVisit(url: page, title: "Persisted", at: Date(timeIntervalSince1970: 500))
    }
    let reopened = try makeStore()
    let entry = try XCTUnwrap(try reopened.loadRecent().first)
    XCTAssertEqual(entry.url, page)
    XCTAssertEqual(entry.title, "Persisted")
    XCTAssertEqual(entry.visitCount, 1)
  }

  func testNonHTTPURLIsRejectedByStore() throws {
    let store = try makeStore()
    XCTAssertThrowsError(try store.recordVisit(url: url("file:///tmp/page"), title: "File"))
    XCTAssertTrue(try store.loadRecent().isEmpty)
  }

  @MainActor
  func testHistoryServiceRejectsNonHTTPURLAndClearsPublishedEntries() throws {
    let service = HistoryService(store: try makeStore())
    XCTAssertNil(service.recordVisit(url: url("about:blank"), title: "Blank"))
    XCTAssertTrue(service.entries.isEmpty)
    _ = service.recordVisit(url: url("https://example.com/service"), title: "Service")
    XCTAssertEqual(service.entries.count, 1)
    service.clear()
    XCTAssertTrue(service.entries.isEmpty)
  }

  func testHistoryDatabaseUsesTheSuppliedIsolatedDirectory() throws {
    let store = try makeStore()
    XCTAssertEqual(store.databaseURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path))
  }
}
