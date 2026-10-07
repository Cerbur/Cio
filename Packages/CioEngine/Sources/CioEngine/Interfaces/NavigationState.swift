import Foundation

/// A snapshot of everything the navigation UI needs (ARCHITECTURE.md section
/// 20). Produced from the CEF callbacks; never derived from a Swift-side
/// history counter.
public struct NavigationState: Equatable, Sendable {
  /// URL of the main frame.
  public var url: URL?
  public var title = ""

  public var isLoading = false
  /// 0...1 while loading; `nil` when Chromium has not reported a value.
  public var loadingProgress: Double?

  public var canGoBack = false
  public var canGoForward = false

  public init(
    url: URL? = nil,
    title: String = "",
    isLoading: Bool = false,
    loadingProgress: Double? = nil,
    canGoBack: Bool = false,
    canGoForward: Bool = false
  ) {
    self.url = url
    self.title = title
    self.isLoading = isLoading
    self.loadingProgress = loadingProgress
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
  }
}

/// A CEF download callback translated into Swift-safe value types. CEF objects
/// are never retained by BrowserSession or exposed beyond BrowserBridge.
public struct BrowserDownloadUpdate: Sendable {
  public let downloadID: UInt32
  public let sourceURL: URL
  public let suggestedFileName: String
  public let metadata: DownloadMetadata
  public let destinationURL: URL?
  public let receivedBytes: Int64
  public let totalBytes: Int64?
  public let isInProgress: Bool
  public let isComplete: Bool
  public let isCancelled: Bool
  public let isInterrupted: Bool

  public init(
    downloadID: UInt32,
    sourceURL: URL,
    suggestedFileName: String,
    metadata: DownloadMetadata,
    destinationURL: URL?,
    receivedBytes: Int64,
    totalBytes: Int64?,
    isInProgress: Bool,
    isComplete: Bool,
    isCancelled: Bool,
    isInterrupted: Bool
  ) {
    self.downloadID = downloadID
    self.sourceURL = sourceURL
    self.suggestedFileName = suggestedFileName
    self.metadata = metadata
    self.destinationURL = destinationURL
    self.receivedBytes = receivedBytes
    self.totalBytes = totalBytes
    self.isInProgress = isInProgress
    self.isComplete = isComplete
    self.isCancelled = isCancelled
    self.isInterrupted = isInterrupted
  }
}

