import CioModel
import Foundation

/// A separate durability boundary for Space names and appearance. Tab writes
/// never rewrite this file; metadata remains available when a tab backup restores.
final class SpaceMetadataStore {
  struct Entry: Codable, Equatable {
    let id: UUID
    let metadata: BrowserSpaceMetadata
  }

  private struct File: Codable {
    var schemaVersion = 1
    let spaces: [Entry]
  }

  let fileURL: URL
  private let backupURL: URL
  private let fileManager: FileManager
  private var entries: [UUID: BrowserSpaceMetadata] = [:]
  private var loaded = false
  private var needsRepair = false

  init(directory: URL, fileManager: FileManager) {
    self.fileManager = fileManager
    fileURL = directory.appendingPathComponent("space-metadata-v1.json")
    backupURL = directory.appendingPathComponent("space-metadata-v1.backup.json")
  }

  private func read(_ url: URL) throws -> (file: File, data: Data) {
    let data = try Data(contentsOf: url)
    let file = try JSONDecoder().decode(File.self, from: data)
    guard file.schemaVersion == 1,
          Set(file.spaces.map(\.id)).count == file.spaces.count,
          file.spaces.allSatisfy({ !$0.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw CocoaError(.fileReadCorruptFile) }
    return (file, data)
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    if let primary = try? read(fileURL) {
      entries = Dictionary(uniqueKeysWithValues: primary.file.spaces.map { ($0.id, $0.metadata) })
    } else {
      needsRepair = fileManager.fileExists(atPath: fileURL.path)
      if let backup = try? read(backupURL) {
        entries = Dictionary(uniqueKeysWithValues: backup.file.spaces.map { ($0.id, $0.metadata) })
        needsRepair = true
      }
    }
  }

  func metadata(for id: UUID) -> BrowserSpaceMetadata? {
    loadIfNeeded()
    return entries[id]
  }

  func requiresSave(_ spaces: [PersistedSpace]) -> Bool {
    loadIfNeeded()
    return needsRepair || spaces.contains {
      entries[$0.id] != BrowserSpaceMetadata(name: $0.name, icon: $0.icon)
    }
  }

  /// Preserve unrelated records: a session recovery copy can still refer to them.
  func save(_ spaces: [PersistedSpace]) throws {
    guard requiresSave(spaces) else { return }
    var updated = entries
    for space in spaces {
      updated[space.id] = BrowserSpaceMetadata(name: space.name, icon: space.icon)
    }
    let parent = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(File(spaces: updated.map { Entry(id: $0.key, metadata: $0.value) }
      .sorted { $0.id.uuidString < $1.id.uuidString }))
    if let previous = try? read(fileURL) {
      // A restored good backup is retained while repairing a damaged primary.
      try write(previous.data, to: backupURL)
    } else {
      try preserveDamaged(fileURL)
    }
    if (try? read(backupURL)) == nil {
      try preserveDamaged(backupURL)
      try write(data, to: backupURL)
    }
    try write(data, to: fileURL)
    entries = updated
    needsRepair = false
  }

  private func preserveDamaged(_ url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    let preserved = url.deletingPathExtension().appendingPathExtension("damaged-\(UUID().uuidString).json")
    try fileManager.moveItem(at: url, to: preserved)
    try? fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: preserved.path)
  }

  private func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
  }
}

/// The session's on-disk projection intentionally has no personalization keys.
/// WorkspaceSessionSnapshot remains a complete in-memory restore/diagnostic value
/// and continues to decode the original combined format during migration.
struct WorkspaceTabSessionFile: Encodable {
  let schemaVersion: Int
  let selectedSpaceID: UUID
  let spaces: [Space]
  let globalPinnedTabIDs: [UUID]
  let selectedGlobalTabID: UUID?

  struct Space: Encodable {
    let id: UUID
    let selectedTabID: UUID?
    let tabs: [PersistedTab]
    let pinnedTabIDs: [UUID]
    let stableTabStack: [UUID]
    let splitGroups: [BrowserSplitLayout]
  }

  init(_ snapshot: WorkspaceSessionSnapshot) {
    schemaVersion = snapshot.schemaVersion
    selectedSpaceID = snapshot.selectedSpaceID
    globalPinnedTabIDs = snapshot.globalPinnedTabIDs
    selectedGlobalTabID = snapshot.selectedGlobalTabID
    spaces = snapshot.spaces.map {
      Space(id: $0.id, selectedTabID: $0.selectedTabID, tabs: $0.tabs,
        pinnedTabIDs: $0.pinnedTabIDs, stableTabStack: $0.stableTabStack, splitGroups: $0.splitGroups)
    }
  }
}
