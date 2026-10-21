import CioModel
@testable import CioEngine
import XCTest

final class SpaceMetadataPersistenceTests: XCTestCase {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func store(in directory: URL) -> SessionStore {
    SessionStore(dataDirectory: directory, environment: [:], arguments: [])
  }

  private func workspace() -> WorkspaceCollection {
    let date = Date(timeIntervalSince1970: 10)
    var workspace = WorkspaceCollection(initialTab: BrowserTab(url: URL(string: "https://example.com")!,
      createdAt: date, lastActivatedAt: date))
    _ = workspace.renameSpace(id: workspace.selectedSpaceID, name: "Coding")
    _ = workspace.setSpaceIcon(id: workspace.selectedSpaceID, icon: .emoji("👩‍💻"))
    return workspace
  }

  func testFilesSeparatePersonalizationFromTabStateAndRestoreTogether() throws {
    let directory = try directory()
    let store = store(in: directory)
    let snapshot = WorkspaceSessionSnapshot(workspace: workspace())
    XCTAssertTrue(store.saveSnapshot(snapshot))
    let session = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.sessionFileURL)) as? [String: Any])
    let spaces = try XCTUnwrap(session["spaces"] as? [[String: Any]])
    XCTAssertNil(spaces[0]["name"])
    XCTAssertNil(spaces[0]["icon"])
    XCTAssertNotNil(spaces[0]["tabs"])
    let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.spaceMetadataFileURL)) as? [String: Any])
    let entries = try XCTUnwrap(metadata["spaces"] as? [[String: Any]])
    XCTAssertNil(entries[0]["tabs"])
    XCTAssertEqual(self.store(in: directory).loadSnapshot(), snapshot)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.spaceMetadataFileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testIconAndNameChangesLeaveBothTabFilesUntouched() throws {
    let directory = try directory()
    let store = store(in: directory)
    var workspace = workspace()
    XCTAssertTrue(store.saveSnapshot(WorkspaceSessionSnapshot(workspace: workspace)))
    let sessionBytes = try Data(contentsOf: store.sessionFileURL)
    let backupBytes = try Data(contentsOf: store.backupFileURL)
    _ = workspace.setSpaceIcon(id: workspace.selectedSpaceID, icon: .systemImage("terminal.fill"))
    _ = workspace.renameSpace(id: workspace.selectedSpaceID, name: "Development")
    let updated = WorkspaceSessionSnapshot(workspace: workspace)
    XCTAssertTrue(store.saveSnapshot(updated))
    XCTAssertEqual(try Data(contentsOf: store.sessionFileURL), sessionBytes)
    XCTAssertEqual(try Data(contentsOf: store.backupFileURL), backupBytes)
    XCTAssertEqual(self.store(in: directory).loadSnapshot(), updated)
  }

  func testTabChangeLeavesMetadataFileUntouched() throws {
    let directory = try directory()
    let store = store(in: directory)
    var workspace = workspace()
    XCTAssertTrue(store.saveSnapshot(WorkspaceSessionSnapshot(workspace: workspace)))
    let metadataBytes = try Data(contentsOf: store.spaceMetadataFileURL)
    let date = Date(timeIntervalSince1970: 20)
    _ = workspace.appendTab(BrowserTab(url: URL(string: "https://example.org")!,
      createdAt: date, lastActivatedAt: date), in: workspace.selectedSpaceID, select: false)
    XCTAssertTrue(store.saveSnapshot(WorkspaceSessionSnapshot(workspace: workspace)))
    XCTAssertEqual(try Data(contentsOf: store.spaceMetadataFileURL), metadataBytes)
  }

  func testLegacyCombinedSessionMigratesBeforeRemovingEmbeddedMetadata() throws {
    let directory = try directory()
    let store = store(in: directory)
    let snapshot = WorkspaceSessionSnapshot(workspace: workspace())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: store.sessionFileURL)
    XCTAssertEqual(store.loadSnapshot(), snapshot)
    XCTAssertTrue(store.needsRepair)
    XCTAssertTrue(store.saveSnapshot(snapshot))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.spaceMetadataFileURL.path))
    let session = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.sessionFileURL)) as? [String: Any])
    let spaces = try XCTUnwrap(session["spaces"] as? [[String: Any]])
    XCTAssertNil(spaces[0]["name"])
    XCTAssertEqual(self.store(in: directory).loadSnapshot(), snapshot)
  }

  func testTabBackupRecoveryKeepsLatestPersonalization() throws {
    let directory = try directory()
    let store = store(in: directory)
    var workspace = workspace()
    let original = WorkspaceSessionSnapshot(workspace: workspace)
    XCTAssertTrue(store.saveSnapshot(original))
    _ = workspace.setSpaceIcon(id: workspace.selectedSpaceID, icon: .systemImage("star.fill"))
    let updated = WorkspaceSessionSnapshot(workspace: workspace)
    XCTAssertTrue(store.saveSnapshot(updated))
    try Data("broken".utf8).write(to: store.sessionFileURL)
    let restored = try XCTUnwrap(self.store(in: directory).loadSnapshot())
    XCTAssertEqual(restored, updated)
  }

  func testDamagedMetadataCannotDiscardTabsAndIsPreservedOnRepair() throws {
    let directory = try directory()
    let store = store(in: directory)
    let snapshot = WorkspaceSessionSnapshot(workspace: workspace())
    XCTAssertTrue(store.saveSnapshot(snapshot))
    let damaged = Data("broken metadata".utf8)
    try damaged.write(to: store.spaceMetadataFileURL)
    let relaunched = self.store(in: directory)
    XCTAssertEqual(relaunched.loadSnapshot(), snapshot)
    XCTAssertTrue(relaunched.needsRepair)
    XCTAssertTrue(relaunched.saveSnapshot(snapshot))
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let preserved = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("space-metadata-v1.damaged-") })
    XCTAssertEqual(try Data(contentsOf: preserved), damaged)
    XCTAssertEqual(self.store(in: directory).loadSnapshot(), snapshot)
  }
}
