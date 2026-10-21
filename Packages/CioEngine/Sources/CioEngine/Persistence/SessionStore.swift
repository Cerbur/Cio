//
//  SessionStore.swift
//  Cio
//
//  File-backed persistence for the durable workspace snapshot. This type owns
//  no domain or runtime objects; it only encodes/decodes the explicit schema
//  and keeps file IO out of the workspace and UI layers.
//

import CioModel
import Foundation

public final class SessionStore {
  static let fileName = "session-v1.json"

  public enum RecoveryStatus: Equatable {
    case none
    case restoredBackup
    case startedFresh
  }

  public let sessionFileURL: URL
  public let backupFileURL: URL
  public let isEnabled: Bool
  public private(set) var recoveryStatus: RecoveryStatus = .none
  public private(set) var needsRepair = false

  private let fileManager: FileManager
  private let spaceMetadataStore: SpaceMetadataStore
  public var spaceMetadataFileURL: URL { spaceMetadataStore.fileURL }
  private var protectsUnreadablePrimary = false

  public init(
    dataDirectory: URL? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments
  ) {
    self.fileManager = fileManager
    self.isEnabled = !arguments.contains("--disable-session-persistence")
      && environment["CIO_DISABLE_SESSION_PERSISTENCE"] != "1"

    let root: URL
    if let dataDirectory {
      root = dataDirectory
    } else if let override = environment["CIO_DATA_DIR"], !override.isEmpty {
      root = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      let supportDirectory = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      root = supportDirectory.appendingPathComponent("Cio", isDirectory: true)
    }
    sessionFileURL = root.appendingPathComponent(Self.fileName, isDirectory: false)
    backupFileURL = root.appendingPathComponent("session-v1.backup.json", isDirectory: false)
    spaceMetadataStore = SpaceMetadataStore(directory: root, fileManager: fileManager)
  }

  /// Restore only a validated UUID graph. Preserve damaged input before any
  /// later save can replace it, then fall back to the last known-good snapshot.
  public func loadSnapshot() -> WorkspaceSessionSnapshot? {
    guard isEnabled else { return nil }
    recoveryStatus = .none
    needsRepair = false
    protectsUnreadablePrimary = false
    let hadPrimary = fileManager.fileExists(atPath: sessionFileURL.path)
    if let snapshot = try? readSnapshot(at: sessionFileURL).snapshot {
      AppLog.session.info("workspace session snapshot restored")
      return restoringMetadata(in: snapshot)
    }
    if hadPrimary {
      // If preservation fails, refuse subsequent writes to the original file.
      protectsUnreadablePrimary = !preserveDamagedPrimary()
      needsRepair = true
    }
    if let backup = try? readSnapshot(at: backupFileURL) {
      recoveryStatus = .restoredBackup
      needsRepair = true
      if !protectsUnreadablePrimary {
        // Repair without rotating: the only surviving good backup stays intact.
        do {
          try writePrivate(backup.data, to: sessionFileURL)
          needsRepair = false
        } catch { /* Retry through the normal save/error path. */ }
      }
      AppLog.session.warning("workspace restored from validated backup")
      return restoringMetadata(in: backup.snapshot)
    }
    if hadPrimary || fileManager.fileExists(atPath: backupFileURL.path) {
      recoveryStatus = .startedFresh
      AppLog.session.warning("workspace recovery unavailable; original files preserved")
    }
    return nil
  }

  private func restoringMetadata(in snapshot: WorkspaceSessionSnapshot) -> WorkspaceSessionSnapshot {
    let spaces = snapshot.spaces.map { space in
      let metadata = spaceMetadataStore.metadata(for: space.id)
        ?? BrowserSpaceMetadata(name: space.name, icon: space.icon)
      return PersistedSpace(id: space.id, name: metadata.name, selectedTabID: space.selectedTabID,
        tabs: space.tabs, pinnedTabIDs: space.pinnedTabIDs, stableTabStack: space.stableTabStack,
        splitGroups: space.splitGroups, icon: metadata.icon)
    }
    // Legacy metadata must be durable before its embedded copy is removed.
    needsRepair = needsRepair || spaceMetadataStore.requiresSave(spaces)
    var restored = WorkspaceSessionSnapshot(schemaVersion: snapshot.schemaVersion,
      selectedSpaceID: snapshot.selectedSpaceID, spaces: spaces)
    restored.globalPinnedTabIDs = snapshot.globalPinnedTabIDs
    restored.selectedGlobalTabID = snapshot.selectedGlobalTabID
    return restored
  }

  private func readSnapshot(at url: URL) throws -> (snapshot: WorkspaceSessionSnapshot, data: Data) {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(WorkspaceSessionSnapshot.self, from: data)
    _ = try WorkspaceCollection(restoring: snapshot)
    return (snapshot, data)
  }

  private func preserveDamagedPrimary() -> Bool {
    do {
      let preserved = sessionFileURL.deletingLastPathComponent()
        .appendingPathComponent("session-v1.damaged-\(UUID().uuidString).json")
      try fileManager.moveItem(at: sessionFileURL, to: preserved)
      restrictFile(at: preserved)
      return true
    } catch {
      AppLog.session.error("damaged workspace could not be preserved; writes blocked")
      return false
    }
  }

  private func restrictFile(at url: URL) {
    try? fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                   ofItemAtPath: url.path)
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    restrictFile(at: url)
  }

  /// Writes a complete snapshot using Foundation's atomic data-write path.
  /// The canonical file is never replaced by a partially-written JSON value.
  @discardableResult
  public func saveSnapshot(_ snapshot: WorkspaceSessionSnapshot) -> Bool {
    guard isEnabled else { return true }
    if protectsUnreadablePrimary {
      // Access permissions may have been repaired since launch. Retry preserving
      // the original rather than leaving the Retry button permanently blocked.
      guard !fileManager.fileExists(atPath: sessionFileURL.path) || preserveDamagedPrimary() else { return false }
      protectsUnreadablePrimary = false
    }

    do {
      // Never rotate invalid domain state into the recovery copy.
      _ = try WorkspaceCollection(restoring: snapshot)
      let parent = sessionFileURL.deletingLastPathComponent()
      try fileManager.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
      // createDirectory attributes are ignored when the directory already
      // exists. Re-apply the private mode so a pre-existing support directory
      // cannot silently weaken the session snapshot boundary.
      try? fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: parent.path)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      // Save personalization first so migrating a legacy session cannot lose it.
      try spaceMetadataStore.save(snapshot.spaces)
      let data = try encoder.encode(WorkspaceTabSessionFile(snapshot))
      if let previous = try? readSnapshot(at: sessionFileURL), previous.data == data {
        needsRepair = false
        return true
      }
      if let previous = try? readSnapshot(at: sessionFileURL) {
        try writePrivate(previous.data, to: backupFileURL)
      } else if fileManager.fileExists(atPath: sessionFileURL.path) {
        guard preserveDamagedPrimary() else { return false }
      }
      // A first save also has a recovery copy. Retain an existing valid backup
      // when the primary was missing/damaged instead of replacing it with fresh state.
      if (try? readSnapshot(at: backupFileURL)) == nil {
        if fileManager.fileExists(atPath: backupFileURL.path) {
          let preserved = parent.appendingPathComponent("session-v1.damaged-backup-\(UUID().uuidString).json")
          try fileManager.moveItem(at: backupFileURL, to: preserved)
          restrictFile(at: preserved)
        }
        try writePrivate(data, to: backupFileURL)
      }
      try writePrivate(data, to: sessionFileURL)
      needsRepair = false
      AppLog.session.info("workspace session snapshot saved")
      return true
    } catch {
      AppLog.session.error("workspace session snapshot save failed")
      return false
    }
  }

}
