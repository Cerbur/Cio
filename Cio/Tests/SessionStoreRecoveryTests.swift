import CioModel
@testable import CioEngine
import XCTest

final class SessionStoreRecoveryTests: XCTestCase {
  private func store() throws -> SessionStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return SessionStore(dataDirectory: root, environment: [:], arguments: [])
  }

  private func snapshot(_ suffix: String) -> WorkspaceSessionSnapshot {
    let date = Date(timeIntervalSince1970: 10)
    var workspace = WorkspaceCollection(initialTab: BrowserTab(url: URL(string: "https://example.com/\(suffix)")!,
      createdAt: date, lastActivatedAt: date))
    let other = BrowserTab(url: URL(string: "https://example.org/\(suffix)")!,
      createdAt: date, lastActivatedAt: date)
    _ = workspace.createSpace(initialTab: other, name: "Work", select: true)
    return WorkspaceSessionSnapshot(workspace: workspace)
  }

  func testCorruptPrimaryRestoresPreviousValidatedWorkspaceAndPreservesBytes() throws {
    let store = try store()
    let previous = snapshot("previous")
    XCTAssertTrue(store.saveSnapshot(previous))
    XCTAssertTrue(store.saveSnapshot(snapshot("latest")))
    let damaged = Data("{broken".utf8)
    try damaged.write(to: store.sessionFileURL)
    XCTAssertEqual(store.loadSnapshot(), previous)
    XCTAssertEqual(store.recoveryStatus, .restoredBackup)
    let files = try FileManager.default.contentsOfDirectory(at: store.sessionFileURL.deletingLastPathComponent(),
                                                           includingPropertiesForKeys: nil)
    let preserved = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("session-v1.damaged-") })
    XCTAssertEqual(try Data(contentsOf: preserved), damaged)
    // A second launch restores the repaired primary without another fallback.
    XCTAssertEqual(store.loadSnapshot(), previous)
    XCTAssertEqual(store.recoveryStatus, .none)
  }

  func testMissingPrimaryCanRecoverFirstSave() throws {
    let store = try store()
    let saved = snapshot("first")
    XCTAssertTrue(store.saveSnapshot(saved))
    try FileManager.default.removeItem(at: store.sessionFileURL)
    XCTAssertEqual(store.loadSnapshot(), saved)
    XCTAssertEqual(store.recoveryStatus, .restoredBackup)
  }

  func testInvalidNewSnapshotCannotReplaceEitherCopy() throws {
    let store = try store()
    let saved = snapshot("good")
    XCTAssertTrue(store.saveSnapshot(saved))
    let primary = try Data(contentsOf: store.sessionFileURL)
    let backup = try Data(contentsOf: store.backupFileURL)
    let invalid = WorkspaceSessionSnapshot(schemaVersion: 999,
      selectedSpaceID: saved.selectedSpaceID, spaces: saved.spaces)
    XCTAssertFalse(store.saveSnapshot(invalid))
    XCTAssertEqual(try Data(contentsOf: store.sessionFileURL), primary)
    XCTAssertEqual(try Data(contentsOf: store.backupFileURL), backup)
  }

  func testBothDamagedFilesSurviveStartingFreshAndSaving() throws {
    let store = try store()
    let damaged = Data("invalid".utf8)
    try damaged.write(to: store.sessionFileURL)
    try damaged.write(to: store.backupFileURL)
    XCTAssertNil(store.loadSnapshot())
    XCTAssertEqual(store.recoveryStatus, .startedFresh)
    XCTAssertTrue(store.saveSnapshot(snapshot("fresh")))
    let files = try FileManager.default.contentsOfDirectory(at: store.sessionFileURL.deletingLastPathComponent(),
                                                           includingPropertiesForKeys: nil)
    let preserved = files.filter { $0.lastPathComponent.contains("damaged-") }
    XCTAssertEqual(preserved.count, 2)
    for file in preserved { XCTAssertEqual(try Data(contentsOf: file), damaged) }
  }

  func testSnapshotCopiesArePrivate() throws {
    let store = try store()
    XCTAssertTrue(store.saveSnapshot(snapshot("private")))
    for url in [store.sessionFileURL, store.backupFileURL] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
  }

  func testFailedBackupWriteDoesNotReplacePrimary() throws {
    let store = try store()
    XCTAssertTrue(store.saveSnapshot(snapshot("saved")))
    let savedBytes = try Data(contentsOf: store.sessionFileURL)
    try FileManager.default.removeItem(at: store.backupFileURL)
    try FileManager.default.createDirectory(at: store.backupFileURL, withIntermediateDirectories: true)
    XCTAssertFalse(store.saveSnapshot(snapshot("unsaved")))
    XCTAssertEqual(try Data(contentsOf: store.sessionFileURL), savedBytes)
  }
}
