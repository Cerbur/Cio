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
}
