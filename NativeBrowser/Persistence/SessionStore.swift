//
//  SessionStore.swift
//  NativeBrowser
//
//  File-backed persistence for the durable workspace snapshot. This type owns
//  no domain or runtime objects; it only encodes/decodes the explicit schema
//  and keeps file IO out of the workspace and UI layers.
//

import Foundation

final class SessionStore {
  static let fileName = "session-v1.json"

  let sessionFileURL: URL
  let isEnabled: Bool

  private let fileManager: FileManager

  init(
    dataDirectory: URL? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments
  ) {
    self.fileManager = fileManager
    self.isEnabled = !arguments.contains("--disable-session-persistence")
      && environment["NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE"] != "1"

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
    sessionFileURL = root.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  /// Loads and validates a complete snapshot. Any malformed or unsupported
  /// file is ignored as a unit; callers start a fresh workspace instead.
  func loadSnapshot() -> WorkspaceSessionSnapshot? {
    guard isEnabled else { return nil }
    guard fileManager.fileExists(atPath: sessionFileURL.path) else { return nil }

    do {
      let data = try Data(contentsOf: sessionFileURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let snapshot = try decoder.decode(WorkspaceSessionSnapshot.self, from: data)
      _ = try WorkspaceCollection(restoring: snapshot)
      AppLog.session.info("workspace session snapshot restored")
      return snapshot
    } catch let error as WorkspaceSessionSnapshotError {
      AppLog.session.warning(
        "workspace session snapshot ignored: \(error.description, privacy: .public)")
    } catch {
      // Do not include the raw data, URL fields or decoder payload in logs.
      AppLog.session.warning("workspace session snapshot ignored: malformed or unreadable data")
    }
    return nil
  }

  /// Writes a complete snapshot using Foundation's atomic data-write path.
  /// The canonical file is never replaced by a partially-written JSON value.
  @discardableResult
  func saveSnapshot(_ snapshot: WorkspaceSessionSnapshot) -> Bool {
    guard isEnabled else { return true }

    do {
      let parent = sessionFileURL.deletingLastPathComponent()
      try fileManager.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: nil)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(snapshot)
      try data.write(to: sessionFileURL, options: [.atomic])

      // Workspace state contains browsing URLs. Keep the file private on
      // filesystems that support POSIX permissions, while allowing the write
      // to succeed on platforms/filesystems where this attribute is absent.
      try? fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: sessionFileURL.path)
      AppLog.session.info("workspace session snapshot saved")
      return true
    } catch {
      AppLog.session.error("workspace session snapshot save failed")
      return false
    }
  }

  @discardableResult
  func removeSnapshot() -> Bool {
    guard isEnabled, fileManager.fileExists(atPath: sessionFileURL.path) else { return true }
    do {
      try fileManager.removeItem(at: sessionFileURL)
      return true
    } catch {
      AppLog.session.error("workspace session snapshot removal failed")
      return false
    }
  }
}
