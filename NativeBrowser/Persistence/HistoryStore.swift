//
//  HistoryStore.swift
//  NativeBrowser
//
//  SQLite-backed application history. SQL is deliberately confined to this
//  type; the service and UI work only with HistoryEntry values.
//

import Combine
import Foundation
import SQLite3

enum HistoryStoreError: Error, Equatable {
  case sqlite(Int32)
  case unsupportedSchema(Int32)
  case invalidRow
}

final class HistoryStore {
  static let fileName = "history.sqlite3"
  static let schemaVersion: Int32 = 1

  let databaseURL: URL

  private var database: OpaquePointer?
  private let fileManager: FileManager

  init(
    dataDirectory: URL? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    self.fileManager = fileManager

    let root: URL
    if let dataDirectory {
      root = dataDirectory
    } else if let override = environment["NATIVEBROWSER_DATA_DIR"], !override.isEmpty {
      root = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      let supportDirectory = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      root = supportDirectory.appendingPathComponent("NativeBrowser", isDirectory: true)
    }

    self.databaseURL = root.appendingPathComponent(Self.fileName, isDirectory: false)
    try openDatabase()
  }

  private init(inMemory: Void) throws {
    fileManager = .default
    databaseURL = URL(fileURLWithPath: ":memory:")
    try openDatabase()
  }

  static func inMemory() -> HistoryStore {
    // The schema creation is deterministic and only fails if the system SQLite
    // library is unavailable, which cannot occur on the supported platform.
    return try! HistoryStore(inMemory: ())
  }

  deinit {
    sqlite3_close(database)
  }

  var userVersion: Int32 {
    (try? scalarInt32("PRAGMA user_version;")) ?? 0
  }

  func loadRecent(limit: Int = 500) throws -> [HistoryEntry] {
    let statement = try prepare(
      """
      SELECT id, url, title, visit_count, first_visited_at, last_visited_at
      FROM history_entries
      ORDER BY last_visited_at DESC, id DESC
      LIMIT ?;
      """)
    defer { sqlite3_finalize(statement) }
    try bind(Int64(max(0, limit)), at: 1, in: statement)

    var result: [HistoryEntry] = []
    var resultCode = sqlite3_step(statement)
    while resultCode == SQLITE_ROW {
      result.append(try entry(from: statement))
      resultCode = sqlite3_step(statement)
    }
    guard resultCode == SQLITE_DONE else {
      throw HistoryStoreError.sqlite(resultCode)
    }
    return result
  }

  @discardableResult
  func recordVisit(url: URL, title: String, at date: Date = Date()) throws -> HistoryEntry {
    guard HistoryURLPolicy.isRecordable(url) else {
      throw HistoryStoreError.invalidRow
    }

    let statement = try prepare(
      """
      INSERT INTO history_entries
        (id, url, title, visit_count, first_visited_at, last_visited_at)
      VALUES (?, ?, ?, 1, ?, ?)
      ON CONFLICT(url) DO UPDATE SET
        visit_count = history_entries.visit_count + 1,
        last_visited_at = excluded.last_visited_at,
        title = CASE
          WHEN excluded.title <> '' THEN excluded.title
          ELSE history_entries.title
        END;
      """)
    defer { sqlite3_finalize(statement) }

    let id = UUID().uuidString
    let urlString = url.absoluteString
    let usefulTitle = HistoryURLPolicy.usefulTitle(title) ?? ""
    try bind(id, at: 1, in: statement)
    try bind(urlString, at: 2, in: statement)
    try bind(usefulTitle, at: 3, in: statement)
    try bind(date.timeIntervalSince1970, at: 4, in: statement)
    try bind(date.timeIntervalSince1970, at: 5, in: statement)
    try stepDone(statement)

    guard let entry = try entry(forExactURL: urlString) else {
      throw HistoryStoreError.invalidRow
    }
    return entry
  }

  func updateTitle(for url: URL, title: String) throws {
    guard let usefulTitle = HistoryURLPolicy.usefulTitle(title) else { return }

    let statement = try prepare(
      "UPDATE history_entries SET title = ? WHERE url = ?;")
    defer { sqlite3_finalize(statement) }
    try bind(usefulTitle, at: 1, in: statement)
    try bind(url.absoluteString, at: 2, in: statement)
    try stepDone(statement)
  }

  func clear() throws {
    try execute("DELETE FROM history_entries;")
  }

  private func openDatabase() throws {
    if databaseURL.path != ":memory:" {
      let directory = databaseURL.deletingLastPathComponent()
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
      try? fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: directory.path)
    }

    var opened: OpaquePointer?
    let path = databaseURL.path
    let result: Int32 = path == ":memory:"
      ? sqlite3_open_v2(":memory:", &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      : sqlite3_open_v2(
        path,
        &opened,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        nil)
    guard result == SQLITE_OK, let opened else {
      if let opened { sqlite3_close(opened) }
      throw HistoryStoreError.sqlite(result)
    }
    database = opened

    do {
      let version = try scalarInt32("PRAGMA user_version;")
      guard version == 0 || version == Self.schemaVersion else {
        throw HistoryStoreError.unsupportedSchema(version)
      }
      if version == 0 {
        try execute(
          """
          CREATE TABLE IF NOT EXISTS history_entries (
            id TEXT PRIMARY KEY NOT NULL,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            visit_count INTEGER NOT NULL,
            first_visited_at REAL NOT NULL,
            last_visited_at REAL NOT NULL
          );
          """)
        try execute("PRAGMA user_version = 1;")
      }
      if databaseURL.path != ":memory:" {
        try? fileManager.setAttributes(
          [.posixPermissions: NSNumber(value: Int16(0o600))],
          ofItemAtPath: databaseURL.path)
      }
    } catch {
      sqlite3_close(database)
      database = nil
      throw error
    }
  }

  private func entry(forExactURL url: String) throws -> HistoryEntry? {
    let statement = try prepare(
      """
      SELECT id, url, title, visit_count, first_visited_at, last_visited_at
      FROM history_entries WHERE url = ? LIMIT 1;
      """)
    defer { sqlite3_finalize(statement) }
    try bind(url, at: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return try entry(from: statement)
  }

  private func entry(from statement: OpaquePointer?) throws -> HistoryEntry {
    guard
      let idString = stringColumn(statement, index: 0),
      let id = UUID(uuidString: idString),
      let urlString = stringColumn(statement, index: 1),
      let url = URL(string: urlString)
    else {
      throw HistoryStoreError.invalidRow
    }

    return HistoryEntry(
      id: id,
      url: url,
      title: stringColumn(statement, index: 2) ?? "",
      visitCount: Int(sqlite3_column_int64(statement, 3)),
      firstVisitedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
      lastVisitedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)))
  }

  private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
  }

  private func scalarInt32(_ sql: String) throws -> Int32 {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw HistoryStoreError.sqlite(sqlite3_errcode(database))
    }
    return sqlite3_column_int(statement, 0)
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw HistoryStoreError.sqlite(sqlite3_errcode(database))
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw HistoryStoreError.sqlite(sqlite3_errcode(database))
    }
    return statement
  }

  private func stepDone(_ statement: OpaquePointer?) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw HistoryStoreError.sqlite(sqlite3_errcode(database))
    }
  }

  private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) throws {
    let result = value.withCString { pointer in
      sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard result == SQLITE_OK else { throw HistoryStoreError.sqlite(result) }
  }

  private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer?) throws {
    let result = sqlite3_bind_int64(statement, index, value)
    guard result == SQLITE_OK else { throw HistoryStoreError.sqlite(result) }
  }

  private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer?) throws {
    let result = sqlite3_bind_double(statement, index, value)
    guard result == SQLITE_OK else { throw HistoryStoreError.sqlite(result) }
  }
}

@MainActor
final class HistoryService: ObservableObject {
  @Published private(set) var entries: [HistoryEntry] = []

  let store: HistoryStore

  init(store: HistoryStore) {
    self.store = store
    reload()
  }

  convenience init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) {
    let store = (try? HistoryStore(fileManager: fileManager, environment: environment))
      ?? HistoryStore.inMemory()
    self.init(store: store)
  }

  func reload() {
    entries = (try? store.loadRecent()) ?? []
  }

  @discardableResult
  func recordVisit(url: URL, title: String, at date: Date = Date()) -> HistoryEntry? {
    guard HistoryURLPolicy.isRecordable(url), let entry = try? store.recordVisit(url: url, title: title, at: date) else {
      return nil
    }
    reload()
    return entry
  }

  func updateTitle(for url: URL, title: String) {
    guard HistoryURLPolicy.isRecordable(url) else { return }
    try? store.updateTitle(for: url, title: title)
    reload()
  }

  func clear() {
    try? store.clear()
    entries.removeAll()
  }
}
