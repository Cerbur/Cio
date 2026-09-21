//
//  WorkspaceSessionSnapshotTests.swift
//  NativeBrowserTests
//
//  CEF-free Milestone 6 persistence and restore tests.
//

import XCTest

final class WorkspaceSessionSnapshotTests: XCTestCase {
  private let firstURL = URL(string: "https://example.com/callback?code=fake-secret-value#fragment-secret")!

  private func tab(
    _ title: String,
    _ url: URL?,
    id: UUID = UUID(),
    createdAt: Date = Date(timeIntervalSince1970: 1),
    lastActivatedAt: Date = Date(timeIntervalSince1970: 2)
  ) -> BrowserTab {
    BrowserTab(
      id: id,
      title: title,
      url: url,
      isLoading: true,
      createdAt: createdAt,
      lastActivatedAt: lastActivatedAt)
  }

  private func populatedWorkspace() -> WorkspaceCollection {
    var workspace = WorkspaceCollection(initialTab: tab("Main A", firstURL))
    let firstSpaceID = workspace.selectedSpaceID
    let secondTab = tab("Main B", URL(string: "https://example.com/main-b"))
    XCTAssertTrue(workspace.appendTab(secondTab, in: firstSpaceID, select: false))
    XCTAssertTrue(workspace.selectTab(id: secondTab.id))

    let secondSpaceTab = tab("Work A", URL(string: "https://example.org/work-a"))
    let secondSpaceID = workspace.createSpace(initialTab: secondSpaceTab, name: "Work")!
    let secondSpaceOtherTab = tab("Work B", URL(string: "https://example.org/work-b"))
    XCTAssertTrue(workspace.appendTab(secondSpaceOtherTab, in: secondSpaceID, select: true))

    XCTAssertTrue(workspace.select(spaceID: firstSpaceID, tabID: secondTab.id))
    return workspace
  }

  private func temporarySessionStore() throws -> (store: SessionStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeBrowser-session-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    return (
      SessionStore(dataDirectory: directory, environment: [:], arguments: []),
      directory)
  }

  private func encodedSnapshot(_ snapshot: WorkspaceSessionSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(snapshot)
  }

  @MainActor
  private func assertFreshMainWorkspace(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let workspace = WorkspaceCollection(
      initialTab: BrowserTab(url: URL(string: "https://www.google.com")!))
    XCTAssertEqual(workspace.spaces.count, 1, file: file, line: line)
    XCTAssertEqual(workspace.spaces.first?.name, "Main", file: file, line: line)
    XCTAssertEqual(workspace.allTabs.count, 1, file: file, line: line)
    XCTAssertNotNil(workspace.selectedTabID, file: file, line: line)
  }

  func testFreshWorkspaceSnapshotRoundTrips() throws {
    let original = populatedWorkspace()
    let snapshot = WorkspaceSessionSnapshot(workspace: original)
    let restored = try WorkspaceCollection(restoring: snapshot)

    XCTAssertEqual(restored.spaces.map(\.id), original.spaces.map(\.id))
    XCTAssertEqual(restored.allTabIDs, original.allTabIDs)
    XCTAssertEqual(restored.selectedSpaceID, original.selectedSpaceID)
    XCTAssertEqual(restored.selectedTabID, original.selectedTabID)
    XCTAssertTrue(restored.validateInvariants())
  }

  func testSpaceAndTabOrderingAndSelectionsArePreserved() throws {
    let original = populatedWorkspace()
    let snapshot = WorkspaceSessionSnapshot(workspace: original)
    let restored = try WorkspaceCollection(restoring: snapshot)

    XCTAssertEqual(restored.spaces.map(\.name), ["Main", "Work"])
    XCTAssertEqual(
      restored.spaces.map { restored.tabs(in: $0.id).map(\.id) },
      original.spaces.map { original.tabs(in: $0.id).map(\.id) })
    XCTAssertEqual(
      restored.spaces.map(\.selectedTabID),
      original.spaces.map(\.selectedTabID))
  }

  func testSpaceAndTabIdentitiesArePreservedAcrossRestore() throws {
    let original = populatedWorkspace()
    let snapshot = WorkspaceSessionSnapshot(workspace: original)
    let restored = try WorkspaceCollection(restoring: snapshot)

    XCTAssertEqual(Set(restored.spaces.map(\.id)), Set(original.spaces.map(\.id)))
    XCTAssertEqual(Set(restored.allTabIDs), Set(original.allTabIDs))
  }

  func testURLsAndTitlesRoundTripExactly() throws {
    let original = populatedWorkspace()
    let snapshot = WorkspaceSessionSnapshot(workspace: original)
    let restored = try WorkspaceCollection(restoring: snapshot)

    XCTAssertEqual(restored.tab(withID: original.allTabIDs[0])?.url, firstURL)
    XCTAssertEqual(restored.tab(withID: original.allTabIDs[0])?.title, "Main A")
    XCTAssertEqual(
      restored.tab(withID: original.allTabIDs[0])?.url?.absoluteString,
      firstURL.absoluteString)
  }

  func testTransientLoadingAndRecentlyClosedStateIsNotPersisted() throws {
    var original = populatedWorkspace()
    let closed = original.allTabs[1]
    _ = original.close(closed.id, reason: .userClosed)
    let snapshot = WorkspaceSessionSnapshot(workspace: original)
    let restored = try WorkspaceCollection(restoring: snapshot)

    XCTAssertTrue(restored.allTabs.allSatisfy { !$0.isLoading })
    XCTAssertTrue(restored.recentlyClosed.isEmpty)
    XCTAssertFalse(snapshot.spaces.flatMap(\.tabs).contains { $0.id == closed.id })
  }

  func testSnapshotEqualityIgnoresRuntimeOnlyStateByConstruction() {
    let loading = WorkspaceCollection(initialTab: tab("Home", firstURL))
    let snapshot = WorkspaceSessionSnapshot(workspace: loading)
    var idle = try! WorkspaceCollection(restoring: snapshot)
    let id = idle.selectedTabID!
    var idleTab = idle.tab(withID: id)!
    idleTab.isLoading = true
    XCTAssertTrue(idle.refresh(idleTab))
    XCTAssertEqual(
      snapshot,
      WorkspaceSessionSnapshot(workspace: idle))
  }

  func testUnsupportedSchemaIsRejected() {
    let snapshot = WorkspaceSessionSnapshot(
      schemaVersion: 999,
      selectedSpaceID: UUID(),
      spaces: [])
    XCTAssertThrowsError(try WorkspaceCollection(restoring: snapshot)) { error in
      XCTAssertEqual(error as? WorkspaceSessionSnapshotError, .unsupportedSchema)
    }
  }

  func testDuplicateSpaceIDIsRejected() {
    let spaceID = UUID()
    let tabA = PersistedTab(
      id: UUID(), title: "A", url: firstURL.absoluteString,
      createdAt: Date(), lastActivatedAt: Date())
    let tabB = PersistedTab(
      id: UUID(), title: "B", url: "https://example.com/b",
      createdAt: Date(), lastActivatedAt: Date())
    let snapshot = WorkspaceSessionSnapshot(
      selectedSpaceID: spaceID,
      spaces: [
        PersistedSpace(id: spaceID, name: "A", selectedTabID: tabA.id, tabs: [tabA]),
        PersistedSpace(id: spaceID, name: "B", selectedTabID: tabB.id, tabs: [tabB]),
      ])

    XCTAssertThrowsError(try WorkspaceCollection(restoring: snapshot)) { error in
      XCTAssertEqual(error as? WorkspaceSessionSnapshotError, .duplicateSpaceID)
    }
  }

  func testDuplicateTabIDIsRejected() {
    let spaceA = UUID()
    let spaceB = UUID()
    let tabID = UUID()
    let tabA = PersistedTab(
      id: tabID, title: "A", url: firstURL.absoluteString,
      createdAt: Date(), lastActivatedAt: Date())
    let tabB = PersistedTab(
      id: tabID, title: "B", url: "https://example.com/b",
      createdAt: Date(), lastActivatedAt: Date())
    let snapshot = WorkspaceSessionSnapshot(
      selectedSpaceID: spaceA,
      spaces: [
        PersistedSpace(id: spaceA, name: "A", selectedTabID: tabID, tabs: [tabA]),
        PersistedSpace(id: spaceB, name: "B", selectedTabID: tabID, tabs: [tabB]),
      ])

    XCTAssertThrowsError(try WorkspaceCollection(restoring: snapshot)) { error in
      XCTAssertEqual(error as? WorkspaceSessionSnapshotError, .duplicateTabID)
    }
  }

  func testDanglingSelectedSpaceIsRejected() {
    let tabID = UUID()
    let spaceID = UUID()
    let snapshot = WorkspaceSessionSnapshot(
      selectedSpaceID: UUID(),
      spaces: [
        PersistedSpace(
          id: spaceID,
          name: "Main",
          selectedTabID: tabID,
          tabs: [PersistedTab(
            id: tabID, title: "A", url: firstURL.absoluteString,
            createdAt: Date(), lastActivatedAt: Date())])
      ])

    XCTAssertThrowsError(try WorkspaceCollection(restoring: snapshot)) { error in
      XCTAssertEqual(error as? WorkspaceSessionSnapshotError, .missingSelectedSpace)
    }
  }

  func testDanglingSelectedTabIsRejected() {
    let spaceID = UUID()
    let tabID = UUID()
    let snapshot = WorkspaceSessionSnapshot(
      selectedSpaceID: spaceID,
      spaces: [
        PersistedSpace(
          id: spaceID,
          name: "Main",
          selectedTabID: UUID(),
          tabs: [PersistedTab(
            id: tabID, title: "A", url: firstURL.absoluteString,
            createdAt: Date(), lastActivatedAt: Date())])
      ])

    XCTAssertThrowsError(try WorkspaceCollection(restoring: snapshot)) { error in
      XCTAssertEqual(error as? WorkspaceSessionSnapshotError, .selectedTabNotInSpace)
    }
  }

  func testInvalidURLIsRejected() {
    let spaceID = UUID()
    let tabID = UUID()
    let snapshot = WorkspaceSessionSnapshot(
      selectedSpaceID: spaceID,
      spaces: [
        PersistedSpace(
          id: spaceID,
          name: "Main",
          selectedTabID: tabID,
          tabs: [PersistedTab(
            id: tabID, title: "A", url: "%%%not-a-url%%",
            createdAt: Date(), lastActivatedAt: Date())])
      ])

    XCTAssertThrowsError(try WorkspaceCollection(restoring: snapshot)) { error in
      XCTAssertEqual(error as? WorkspaceSessionSnapshotError, .invalidURL)
    }
  }

  func testMalformedJSONFailsSafely() {
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        WorkspaceSessionSnapshot.self,
        from: Data("{ definitely-not-json".utf8)))
  }

  @MainActor
  func testMissingSessionFileStartsFreshMainWorkspace() throws {
    let (store, directory) = try temporarySessionStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertNil(store.loadSnapshot())
    assertFreshMainWorkspace()
  }

  @MainActor
  func testSessionStoreLoadsValidSnapshotAndRestoresIt() throws {
    let (store, directory) = try temporarySessionStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = WorkspaceSessionSnapshot(workspace: populatedWorkspace())

    XCTAssertTrue(store.saveSnapshot(snapshot))
    let loaded = try XCTUnwrap(store.loadSnapshot())
    XCTAssertEqual(loaded.schemaVersion, snapshot.schemaVersion)
    XCTAssertEqual(loaded.selectedSpaceID, snapshot.selectedSpaceID)
    XCTAssertEqual(loaded.spaces.map(\.id), snapshot.spaces.map(\.id))
    XCTAssertEqual(loaded.spaces.map(\.name), snapshot.spaces.map(\.name))
    XCTAssertEqual(
      loaded.spaces.flatMap(\.tabs).map(\.id),
      snapshot.spaces.flatMap(\.tabs).map(\.id))
    XCTAssertEqual(
      loaded.spaces.flatMap(\.tabs).map(\.title),
      snapshot.spaces.flatMap(\.tabs).map(\.title))
    XCTAssertEqual(
      loaded.spaces.flatMap(\.tabs).map(\.url),
      snapshot.spaces.flatMap(\.tabs).map(\.url))
    XCTAssertEqual(
      loaded.spaces.flatMap(\.tabs).map { Int($0.createdAt.timeIntervalSince1970) },
      snapshot.spaces.flatMap(\.tabs).map { Int($0.createdAt.timeIntervalSince1970) })
    XCTAssertEqual(
      loaded.spaces.flatMap(\.tabs).map { Int($0.lastActivatedAt.timeIntervalSince1970) },
      snapshot.spaces.flatMap(\.tabs).map { Int($0.lastActivatedAt.timeIntervalSince1970) })
    let workspace = try WorkspaceCollection(restoring: loaded)
    XCTAssertEqual(WorkspaceSessionSnapshot(workspace: workspace), loaded)
  }

  @MainActor
  func testSessionStoreRejectsCorruptSnapshotsAndStartsFreshMainWorkspace() throws {
    let spaceID = UUID()
    let otherSpaceID = UUID()
    let selectedTabID = UUID()
    let otherTabID = UUID()
    let baseTab = PersistedTab(
      id: selectedTabID,
      title: "Main",
      url: firstURL.absoluteString,
      createdAt: Date(timeIntervalSince1970: 1),
      lastActivatedAt: Date(timeIntervalSince1970: 2))
    let otherTab = PersistedTab(
      id: otherTabID,
      title: "Other",
      url: "https://example.com/other",
      createdAt: Date(timeIntervalSince1970: 3),
      lastActivatedAt: Date(timeIntervalSince1970: 4))
    let validSpace = PersistedSpace(
      id: spaceID,
      name: "Main",
      selectedTabID: selectedTabID,
      tabs: [baseTab])

    let corruptFiles: [(String, Data)] = [
      ("malformed JSON", Data("{ definitely-not-json".utf8)),
      ("unsupported schema", try encodedSnapshot(WorkspaceSessionSnapshot(
        schemaVersion: 999,
        selectedSpaceID: spaceID,
        spaces: [validSpace]))),
      ("duplicate tab IDs", try encodedSnapshot(WorkspaceSessionSnapshot(
        selectedSpaceID: spaceID,
        spaces: [
          validSpace,
          PersistedSpace(
            id: otherSpaceID,
            name: "Other",
            selectedTabID: selectedTabID,
            tabs: [otherTab, baseTab]),
        ]))),
      ("missing selected Space", try encodedSnapshot(WorkspaceSessionSnapshot(
        selectedSpaceID: UUID(),
        spaces: [validSpace]))),
      ("selected tab outside Space", try encodedSnapshot(WorkspaceSessionSnapshot(
        selectedSpaceID: spaceID,
        spaces: [PersistedSpace(
          id: spaceID,
          name: "Main",
          selectedTabID: otherTabID,
          tabs: [baseTab])]))),
    ]

    for (label, data) in corruptFiles {
      let (store, directory) = try temporarySessionStore()
      defer { try? FileManager.default.removeItem(at: directory) }
      try data.write(to: store.sessionFileURL, options: [.atomic])

      XCTAssertNil(store.loadSnapshot(), label)
      assertFreshMainWorkspace(file: #filePath, line: #line)
    }
  }
}
