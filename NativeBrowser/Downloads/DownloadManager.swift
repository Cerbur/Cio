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
    now: Date = Date()
  ) -> URL? {
    if let existingID = itemIDsByCEFDownloadID[downloadID],
      let index = items.firstIndex(where: { $0.id == existingID }),
      let destination = items[index].destinationURL
    {
      return destination
    }

    guard let destination = uniqueDestination(for: suggestedFileName) else { return nil }
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
      item.destinationURL = uniqueDestination(for: suggestedFileName)
      item.fileName = item.destinationURL?.lastPathComponent ?? Self.sanitizedFileName(suggestedFileName)
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

  private func uniqueDestination(for suggestion: String) -> URL? {
    if !fileManager.fileExists(atPath: downloadsDirectoryURL.path) {
      try? fileManager.createDirectory(
        at: downloadsDirectoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    }
    guard fileManager.fileExists(atPath: downloadsDirectoryURL.path) else { return nil }

    let name = Self.sanitizedFileName(suggestion)
    let extensionName = (name as NSString).pathExtension
    let stem = extensionName.isEmpty
      ? name
      : String(name.dropLast(extensionName.count + 1))
    let reservedDestinations = Set(
      items.compactMap { $0.destinationURL?.standardizedFileURL })

    var suffix = 0
    while true {
      let candidateName: String
      if suffix == 0 {
        candidateName = name
      } else if extensionName.isEmpty {
        candidateName = "\(stem) (\(suffix))"
      } else {
        candidateName = "\(stem) (\(suffix)).\(extensionName)"
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
    let candidate = url.standardizedFileURL
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path.hasPrefix(prefix)
  }
}
