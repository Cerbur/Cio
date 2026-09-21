//
//  DownloadManager.swift
//  NativeBrowser
//
//  Application-level download state and destination policy. CEF identifiers
//  are kept only as an internal correlation key; no CEF type crosses here.
//

import AppKit
import Combine
import Foundation

/// Filename and response metadata translated from CEF into Swift value types.
/// CEF objects never cross into the application model.
struct DownloadMetadata: Equatable, Sendable {
  let cefSuggestedFileName: String
  let contentDisposition: String
  let mimeType: String
  let originalURL: URL?

  static let empty = DownloadMetadata(
    cefSuggestedFileName: "",
    contentDisposition: "",
    mimeType: "",
    originalURL: nil)
}

enum DownloadState: Equatable, Sendable {
  case pending
  case downloading
  case completed
  case failed
  case cancelled

  var displayName: String {
    switch self {
    case .pending: return "Pending"
    case .downloading: return "Downloading"
    case .completed: return "Completed"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }

  var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled: return true
    case .pending, .downloading: return false
    }
  }
}

struct DownloadItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let cefDownloadID: UInt32
  var fileName: String
  var sourceURL: URL
  var destinationURL: URL?
  var receivedBytes: Int64
  var totalBytes: Int64?
  var state: DownloadState
  var startedAt: Date
  var finishedAt: Date?

  var progress: Double? {
    guard let totalBytes, totalBytes > 0 else { return nil }
    return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
  }
}

@MainActor
final class DownloadManager: ObservableObject {
  @Published private(set) var items: [DownloadItem] = []

  let downloadsDirectoryURL: URL

  private let fileManager: FileManager
  private var itemIDsByCEFDownloadID: [UInt32: UUID] = [:]

  init(
    downloadsDirectory: URL? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.fileManager = fileManager

    if let downloadsDirectory {
      downloadsDirectoryURL = downloadsDirectory
    } else if let override = environment["NATIVEBROWSER_DOWNLOADS_DIR"], !override.isEmpty {
      downloadsDirectoryURL = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      downloadsDirectoryURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
          .appendingPathComponent("Downloads", isDirectory: true)
    }

    try? fileManager.createDirectory(
      at: downloadsDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
  }

  var activeDownloadCount: Int {
    items.filter { !$0.state.isTerminal }.count
  }

  /// Called by the bridge's OnBeforeDownload path. The same CEF identifier
  /// always receives the same destination, even if CEF repeats the callback.
  @discardableResult
  func prepareDownload(
    downloadID: UInt32,
    sourceURL: URL,
    suggestedFileName: String,
    metadata: DownloadMetadata = .empty,
    now: Date = Date()
  ) -> URL? {
    if let existingID = itemIDsByCEFDownloadID[downloadID],
      let index = items.firstIndex(where: { $0.id == existingID }),
      let destination = items[index].destinationURL
    {
      return destination
    }

    let resolvedFileName = Self.resolvedFileName(
      sourceURL: sourceURL,
      suggestedFileName: suggestedFileName,
      metadata: metadata)
    guard let destination = uniqueDestination(for: resolvedFileName) else { return nil }
    let sanitizedName = destination.lastPathComponent
    if let existingID = itemIDsByCEFDownloadID[downloadID],
      let index = items.firstIndex(where: { $0.id == existingID })
    {
      items[index].fileName = sanitizedName
      items[index].sourceURL = sourceURL
      items[index].destinationURL = destination
      if items[index].state == .pending { items[index].startedAt = now }
      return destination
    }

    let item = DownloadItem(
      id: UUID(),
      cefDownloadID: downloadID,
      fileName: sanitizedName,
      sourceURL: sourceURL,
      destinationURL: destination,
      receivedBytes: 0,
      totalBytes: nil,
      state: .pending,
      startedAt: now,
      finishedAt: nil)
    items.insert(item, at: 0)
    itemIDsByCEFDownloadID[downloadID] = item.id
    return destination
  }

  /// Applies one real CEF progress callback. Repeated callbacks update the
  /// existing item by CEF identifier instead of appending another row.
  func update(
    downloadID: UInt32,
    sourceURL: URL,
    suggestedFileName: String,
    metadata: DownloadMetadata = .empty,
    destinationURL: URL?,
    receivedBytes: Int64,
    totalBytes: Int64?,
    isInProgress: Bool,
    isComplete: Bool,
    isCancelled: Bool,
    isInterrupted: Bool,
    now: Date = Date()
  ) {
    let index: Int
    if let existingID = itemIDsByCEFDownloadID[downloadID],
      let existingIndex = items.firstIndex(where: { $0.id == existingID })
    {
      index = existingIndex
    } else {
      _ = prepareDownload(
        downloadID: downloadID,
        sourceURL: sourceURL,
        suggestedFileName: suggestedFileName,
        metadata: metadata,
        now: now)
      guard let newID = itemIDsByCEFDownloadID[downloadID],
        let newIndex = items.firstIndex(where: { $0.id == newID }) else { return }
      index = newIndex
    }

    var item = items[index]
    item.sourceURL = sourceURL
    if let safeDestination = destinationURL.flatMap({ containedURL($0) ? $0 : nil }) {
      item.destinationURL = safeDestination
      item.fileName = safeDestination.lastPathComponent
    }
    if item.destinationURL == nil {
      let resolvedFileName = Self.resolvedFileName(
        sourceURL: sourceURL,
        suggestedFileName: suggestedFileName,
        metadata: metadata)
      item.destinationURL = uniqueDestination(for: resolvedFileName)
      item.fileName = item.destinationURL?.lastPathComponent
        ?? Self.sanitizedFileName(resolvedFileName)
    }
    item.receivedBytes = max(0, receivedBytes)
    item.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }

    let newState: DownloadState
    if isCancelled {
      newState = .cancelled
    } else if isInterrupted {
      newState = .failed
    } else if isComplete {
      newState = .completed
    } else if isInProgress {
      newState = .downloading
    } else {
      newState = .pending
    }
    // CEF may refresh the same item after its terminal update (for example
    // while it refreshes the download row's path). Never move a terminal item
    // back to another state: the first terminal result is authoritative for
    // this process-memory download record.
    if !item.state.isTerminal {
      item.state = newState
    }
    if newState.isTerminal, item.finishedAt == nil {
      item.finishedAt = now
    }
    items[index] = item
  }

  func open(_ item: DownloadItem) {
    guard let destination = item.destinationURL, containedURL(destination) else { return }
    NSWorkspace.shared.open(destination)
  }

  func showInFinder(_ item: DownloadItem) {
    guard let destination = item.destinationURL, containedURL(destination) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([destination])
  }

  static func sanitizedFileName(_ suggestion: String) -> String {
    var result = suggestion
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\\", with: "_")
      .unicodeScalars
      .filter { $0.value >= 0x20 && $0.value != 0x7F }
      .map(String.init)
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if result.isEmpty || result == "." || result == ".." {
      result = "download"
    }
    return result
  }

  /// Resolves a safe user-visible filename from the strongest metadata CEF
  /// provides. Content-Disposition is parsed here because the installed CEF
  /// build exposes the raw header even when its callback suggestion is the
  /// generic name "download".
  static func resolvedFileName(
    sourceURL: URL,
    suggestedFileName: String,
    metadata: DownloadMetadata = .empty
  ) -> String {
    if let headerName = contentDispositionFileName(metadata.contentDisposition) {
      return sanitizedFileName(headerName)
    }

    let metadataNames = [metadata.cefSuggestedFileName, suggestedFileName]
      .compactMap(usableFileName)
    if let name = metadataNames.first(where: { !isGenericDownloadName($0) }) {
      return nameWithMIMEExtension(name, mimeType: metadata.mimeType)
    }

    let urlNames = [metadata.originalURL, sourceURL]
      .compactMap { $0 }
      .compactMap(urlPathFileName)
    if let name = urlNames.first(where: { !isGenericDownloadName($0) }) {
      return nameWithMIMEExtension(name, mimeType: metadata.mimeType)
    }

    if let name = metadataNames.first {
      return nameWithMIMEExtension(name, mimeType: metadata.mimeType)
    }
    return nameWithMIMEExtension("download", mimeType: metadata.mimeType)
  }

  private func uniqueDestination(for suggestion: String) -> URL? {
    if !fileManager.fileExists(atPath: downloadsDirectoryURL.path) {
      try? fileManager.createDirectory(
        at: downloadsDirectoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    }
    guard fileManager.fileExists(atPath: downloadsDirectoryURL.path) else { return nil }

    let name = Self.sanitizedFileName(suggestion)
    let components = Self.filenameComponents(name)
    let reservedDestinations = Set(
      items.compactMap { $0.destinationURL?.standardizedFileURL })

    var suffix = 0
    while true {
      let candidateName: String
      if suffix == 0 {
        candidateName = name
      } else {
        candidateName = components.extensionName.isEmpty
          ? "\(components.stem) (\(suffix))"
          : "\(components.stem) (\(suffix))\(components.extensionName)"
      }
      let candidate = downloadsDirectoryURL.appendingPathComponent(candidateName, isDirectory: false)
      guard containedURL(candidate) else { return nil }
      if !fileManager.fileExists(atPath: candidate.path)
        && !reservedDestinations.contains(candidate.standardizedFileURL)
      {
        return candidate
      }
      suffix += 1
    }
  }

  private func containedURL(_ url: URL) -> Bool {
    let root = downloadsDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path.hasPrefix(prefix)
  }

  private static func usableFileName(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
    return sanitizedFileName(trimmed)
  }

  private static func urlPathFileName(_ url: URL) -> String? {
    guard let rawComponent = url.path
      .split(separator: "/", omittingEmptySubsequences: true)
      .last
      .map(String.init),
      !rawComponent.isEmpty
    else {
      return nil
    }
    let decoded = rawComponent.removingPercentEncoding ?? rawComponent
    return usableFileName(decoded)
  }

  private static func isGenericDownloadName(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    if lowercased == "download" { return true }
    guard lowercased.hasPrefix("download ("), lowercased.hasSuffix(")") else {
      return false
    }
    let number = lowercased.dropFirst("download (".count).dropLast()
    return Int(number) != nil
  }

  private static func nameWithMIMEExtension(_ name: String, mimeType: String) -> String {
    guard filenameComponents(name).extensionName.isEmpty,
      let extensionName = mimeTypeExtension(mimeType) else {
      return name
    }
    return "\(name).\(extensionName)"
  }

  private static func mimeTypeExtension(_ mimeType: String) -> String? {
    let normalized = mimeType
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    switch normalized {
    case "application/pdf": return "pdf"
    case "application/zip": return "zip"
    case "application/gzip", "application/x-gzip": return "gz"
    case "application/x-tar": return "tar"
    case "application/json": return "json"
    case "text/plain": return "txt"
    case "text/csv": return "csv"
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/gif": return "gif"
    case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
      return "docx"
    case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
      return "xlsx"
    case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
      return "pptx"
    default: return nil
    }
  }

  /// Returns a stem and an extension that includes its leading dot. Recognizing
  /// common compound archive extensions keeps collision suffixes before the
  /// entire extension: package (1).tar.gz.
  private static func filenameComponents(_ name: String) -> (stem: String, extensionName: String) {
    let compoundExtensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"]
    let lowercased = name.lowercased()
    for extensionName in compoundExtensions where lowercased.hasSuffix(extensionName) {
      let stemEnd = name.index(name.endIndex, offsetBy: -extensionName.count)
      guard stemEnd > name.startIndex else { continue }
      return (String(name[..<stemEnd]), String(name[stemEnd...]))
    }

    let extensionName = (name as NSString).pathExtension
    guard !extensionName.isEmpty else { return (name, "") }
    let stem = String(name.dropLast(extensionName.count + 1))
    return (stem, ".\(extensionName)")
  }

  private static func contentDispositionFileName(_ header: String) -> String? {
    guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let parameters = splitHeaderParameters(header).dropFirst()
    var plainName: String?

    for parameter in parameters {
      guard let equals = parameter.firstIndex(of: "=") else { continue }
      let key = parameter[..<equals]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      var value = parameter[parameter.index(after: equals)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
        value.removeFirst()
        value.removeLast()
      }
      guard !value.isEmpty else { continue }

      if key == "filename*" {
        if let separator = value.range(of: "''") {
          value = String(value[separator.upperBound...])
        }
        return value.removingPercentEncoding ?? value
      }
      if key == "filename" {
        plainName = String(value)
      }
    }
    return plainName
  }

  private static func splitHeaderParameters(_ header: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quoted = false
    var escaped = false

    for character in header {
      if escaped {
        current.append(character)
        escaped = false
      } else if quoted && character == "\\" {
        escaped = true
      } else if character == "\"" {
        quoted.toggle()
        current.append(character)
      } else if character == ";" && !quoted {
        result.append(current)
        current.removeAll(keepingCapacity: true)
      } else {
        current.append(character)
      }
    }
    result.append(current)
    return result
  }
}
