import CioEngine
import CioModel
import Foundation

/// Shared fallback requests are deduplicated and bounded, including failures.
/// Chromium supplies live icons; these requests cover unvisited restored tabs.
actor TabFaviconCache {
  static let shared = TabFaviconCache()
  private struct Entry {
    let data: Data?
    let expires: Date?
  }
  private var entries: BoundedLRUCache<URL, Entry>
  private var pending: [URL: Task<Data?, Never>] = [:]
  private let fetch: @Sendable (URL) async -> Data?
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: configuration)
  }()

  init(countLimit: Int = 256, byteLimit: Int = 4 * 1024 * 1024,
       fetch: (@Sendable (URL) async -> Data?)? = nil) {
    entries = BoundedLRUCache(countLimit: countLimit, costLimit: byteLimit)
    self.fetch = fetch ?? Self.fetchData
  }

  func data(for url: URL, now: Date = Date()) async -> Data? {
    guard !Task.isCancelled else { return nil }
    if let entry = entries.value(for: url) {
      if entry.expires.map({ $0 > now }) ?? true { return entry.data }
      entries.remove(url)
    }
    if let task = pending[url] { return await task.value }
    // Wait for a request slot instead of leaving later visible tabs with a
    // permanent placeholder. Cancelled/removed SwiftUI views stop waiting.
    while pending.count >= 16, pending[url] == nil {
      try? await Task.sleep(for: .milliseconds(50))
      guard !Task.isCancelled else { return nil }
      if let entry = entries.value(for: url) {
        if entry.expires.map({ $0 > now }) ?? true { return entry.data }
        entries.remove(url)
      }
    }
    if let task = pending[url] { return await task.value }
    let task = Task.detached(priority: .utility) { [fetch] in
      guard let data = await fetch(url) else { return nil as Data? }
      return BrowserArtwork.normalized(data, as: .favicon)
    }
    pending[url] = task
    let result = await task.value
    entries.insert(Entry(data: result, expires: result == nil ? now.addingTimeInterval(300) : nil),
                   for: url, cost: result?.count ?? 0)
    pending[url] = nil
    return result
  }

  private static func fetchData(_ url: URL) async -> Data? {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
            response.expectedContentLength <= 1024 * 1024 else { return nil }
      var data = Data()
      for try await byte in bytes {
        guard !Task.isCancelled, data.count < 1024 * 1024 else { return nil }
        data.append(byte)
      }
      return data.isEmpty ? nil : data
    } catch { return nil }
  }
}
