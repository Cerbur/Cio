import CryptoKit
import Foundation

/// Disposable, profile-local JPEG cache. All filesystem work runs on this
/// actor, away from AppKit. Filename identity includes both tab and exact URL;
/// modification dates persist LRU touches without rewriting a manifest.
public actor PagePreviewStore {
  public struct Limits: Sendable {
    public var count: Int
    public var bytes: Int
    public init(count: Int = 100, bytes: Int = 8 * 1024 * 1024) {
      self.count = max(0, count); self.bytes = max(0, bytes)
    }
  }
  private struct Entry {
    let size: Int
    var accessed: Date
  }
  private let directory: URL?
  private let limits: Limits
  private var entries: [String: Entry] = [:]
  private var loaded = false
  private let files = FileManager.default

  public init(directory: URL?, limits: Limits = Limits()) {
    self.directory = directory
    self.limits = limits
  }

  public static func key(tabID: UUID, url: URL?) -> String {
    let digest = SHA256.hash(data: Data((url?.absoluteString ?? "").utf8))
      .map { String(format: "%02x", $0) }.joined()
    return tabID.uuidString + "-" + digest + ".jpg"
  }

  public func data(tabID: UUID, url: URL?) -> Data? {
    load()
    let key = Self.key(tabID: tabID, url: url)
    guard let directory, entries[key] != nil else { return nil }
    let path = directory.appendingPathComponent(key)
    guard let handle = try? FileHandle(forReadingFrom: path) else { remove(key); return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: BrowserArtwork.Kind.preview.byteLimit + 1),
          data.count == entries[key]?.size else { remove(key); return nil }
    // Older cache entries may fit the byte budget but still have larger pixels.
    // Normalize those on the actor instead of losing the saved restart preview.
    let result: Data
    if BrowserArtwork.decode(data, as: .preview) != nil { result = data }
    else if let smaller = BrowserArtwork.normalized(data, as: .preview) {
      store(smaller, tabID: tabID, url: url)
      result = smaller
    } else { remove(key); return nil }
    touch(tabID: tabID, url: url)
    return result
  }

  public func touch(tabID: UUID, url: URL?) {
    touch([Self.key(tabID: tabID, url: url): Date()])
  }

  /// Coalesced memory-cache reads retain their actual access times, rather than
  /// assigning every entry the batch's flush time and losing their LRU order.
  public func touch(_ accesses: [String: Date]) {
    load()
    guard let directory else { return }
    for (key, accessed) in accesses {
      // A queued read must neither resurrect an invalidated file nor move a
      // newer capture/read backwards in recency.
      guard let entry = entries[key], accessed > entry.accessed else { continue }
      entries[key]?.accessed = accessed
      try? files.setAttributes([.modificationDate: accessed], ofItemAtPath: directory.appendingPathComponent(key).path)
    }
  }

  public func store(_ data: Data, tabID: UUID, url: URL?) {
    load()
    guard let directory, limits.count > 0, data.count <= limits.bytes,
          BrowserArtwork.decode(data, as: .preview) != nil else { return }
    let key = Self.key(tabID: tabID, url: url)
    do {
      try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
      try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      // Prune before writing, so even the atomic replacement has bounded cost.
      guard remove(key) else { return }
      for old in Array(entries.keys) where old.hasPrefix(tabID.uuidString + "-") {
        guard remove(old) else { return }
      }
      evict(reserving: data.count, count: 1)
      guard entries.count + 1 <= limits.count,
            entries.values.reduce(0, { $0 + $1.size }) + data.count <= limits.bytes else { return }
      let path = directory.appendingPathComponent(key)
      try data.write(to: path, options: .atomic)
      entries[key] = Entry(size: data.count, accessed: Date())
      try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    } catch { /* A cache failure never prevents browsing or workspace restore. */ }
  }

  public func invalidate(tabID: UUID) {
    load()
    for key in Array(entries.keys) where key.hasPrefix(tabID.uuidString + "-") { remove(key) }
  }

  public func retain(_ tabs: [UUID: URL]) {
    load()
    let valid = Set(tabs.map { Self.key(tabID: $0.key, url: $0.value) })
    for key in Array(entries.keys) where !valid.contains(key) { remove(key) }
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    guard let directory,
          let contents = try? files.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return }
    for path in contents where path.pathExtension == "jpg" {
      let name = path.lastPathComponent
      guard name.count == 105, UUID(uuidString: String(name.prefix(36))) != nil else { continue }
      guard let info = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
            info.isRegularFile == true, info.isSymbolicLink != true,
            let size = info.fileSize, size > 0, size <= 512 * 1024 else {
        try? files.removeItem(at: path); continue
      }
      let accessed = info.contentModificationDate ?? .distantPast
      var storedSize = size
      if size > BrowserArtwork.Kind.preview.byteLimit {
        // One-time migration of larger JPEGs produced by the earlier policy.
        // Keep their read recency so startup conversion does not reorder LRU.
        guard let handle = try? FileHandle(forReadingFrom: path) else { continue }
        let raw = try? handle.read(upToCount: 512 * 1024 + 1)
        try? handle.close()
        guard let raw, let smaller = BrowserArtwork.normalized(raw, as: .preview) else {
          try? files.removeItem(at: path); continue
        }
        do {
          try smaller.write(to: path, options: .atomic)
          try files.setAttributes([.modificationDate: accessed, .posixPermissions: 0o600], ofItemAtPath: path.path)
          storedSize = smaller.count
        } catch { entries[name] = Entry(size: size, accessed: accessed); continue }
      }
      entries[name] = Entry(size: storedSize, accessed: accessed)
    }
    evict()
  }

  private func evict(reserving bytes: Int = 0, count: Int = 0) {
    var size = entries.values.reduce(0) { $0 + $1.size }
    let oldest = entries.keys.sorted {
      entries[$0]!.accessed == entries[$1]!.accessed ? $0 < $1 : entries[$0]!.accessed < entries[$1]!.accessed
    }
    for key in oldest {
      guard entries.count + count > limits.count || size + bytes > limits.bytes else { break }
      let removedSize = entries[key]!.size
      if remove(key) { size -= removedSize }
    }
  }

  @discardableResult
  private func remove(_ key: String) -> Bool {
    if let directory {
      let path = directory.appendingPathComponent(key)
      if files.fileExists(atPath: path.path) {
        do { try files.removeItem(at: path) }
        catch { return false } // Keep its cost accounted for if deletion failed.
      }
    }
    entries.removeValue(forKey: key)
    return true
  }
}
