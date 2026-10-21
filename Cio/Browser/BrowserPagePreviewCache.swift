import AppKit
import Combine
import CioEngine
import CioModel

/// Only bounded compositor thumbnails are retained. Disk work is profile-local
/// and asynchronous; it never creates a browser, navigates, or captures a screen.
@MainActor
final class BrowserPagePreviewCache {
  let imagesDidChange = PassthroughSubject<Void, Never>()
  private struct Preview { let image: NSImage? }
  private var images = BoundedLRUCache<String, Preview>(countLimit: 15, costLimit: 8 * 1024 * 1024)
  private var reads: [UUID: UUID] = [:]
  private var captures: [UUID: UUID] = [:]
  private let store: PagePreviewStore
  private var diskWork: Task<Void, Never>?
  // Operational cache bookkeeping, independent of visual animation speed.
  private static let recencyFlushInterval: Duration = .seconds(1)
  private var pendingRecency: [String: Date] = [:]
  private var recencyFlush: Task<Void, Never>?
  private var draining = false
  private var drainCompletion: (@MainActor () -> Void)?
  private var drainTimeout: Task<Void, Never>?

  init(directory: URL?) { store = PagePreviewStore(directory: directory) }

  func image(for id: UUID, url: URL?) -> NSImage? {
    let key = PagePreviewStore.key(tabID: id, url: url)
    if let preview = images.value(for: key) {
      if preview.image != nil { recordAccess(to: key) }
      return preview.image
    }
    guard reads[id] == nil, reads.count < 15 else { return nil }
    let token = UUID()
    reads[id] = token
    flushRecency()
    let preceding = diskWork
    Task { [weak self, store] in
      await preceding?.value
      let data = await store.data(tabID: id, url: url)
      guard let self, self.reads[id] == token else { return }
      self.reads[id] = nil
      if let data, let raster = BrowserArtwork.decode(data, as: .preview) {
        self.images.insert(Preview(image: NSImage(cgImage: raster, size: .zero)), for: key,
                           cost: raster.width * raster.height * 4)
      } else {
        // Negative hits are count-bounded as well; repeated view updates must
        // not continually reread missing/corrupt files.
        self.images.insert(Preview(image: nil), for: key, cost: 0)
      }
      self.imagesDidChange.send(())
    }
    return nil
  }

  func restore(tabs: [BrowserTab], recentIDs: [UUID]) {
    let urls = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
      tab.url.map { (tab.id, $0) }
    })
    enqueue { await $0.retain(urls) }
    for id in recentIDs.prefix(15) { _ = image(for: id, url: urls[id]) }
  }

  func invalidate(_ id: UUID) {
    for key in images.keys where key.hasPrefix(id.uuidString + "-") { images.remove(key) }
    pendingRecency = pendingRecency.filter { !$0.key.hasPrefix(id.uuidString + "-") }
    reads[id] = nil
    captures[id] = nil
    enqueue { await $0.invalidate(tabID: id) }
  }

  func capture(_ session: BrowserSession, completion: (@MainActor (NSImage?) -> Void)? = nil) {
    let id = session.tabID, url = session.url
    guard !draining, session.isSurfaceVisible, !session.isLoading, !session.isClosed,
          captures[id] == nil, captures.count < 15 else {
      completion?(image(for: id, url: url)); return
    }
    let token = UUID()
    captures[id] = token
    session.capturePagePreview { [weak self, weak session] image in
      guard let self, self.captures[id] == token else { completion?(nil); return }
      self.captures[id] = nil
      defer { self.drainIfIdle() }
      guard let session, session.tabID == id, !session.isClosed,
            session.url == url, !session.isLoading else { completion?(nil); return }
      guard let image, let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let data = BrowserArtwork.encode(raster, as: .preview),
            let thumbnail = BrowserArtwork.decode(data, as: .preview) else {
        completion?(self.image(for: id, url: url)); return
      }
      self.reads[id] = nil // An older disk read may not replace this fresh image.
      let result = NSImage(cgImage: thumbnail, size: .zero)
      self.images.insert(Preview(image: result), for: PagePreviewStore.key(tabID: id, url: url),
                         cost: thumbnail.width * thumbnail.height * 4)
      self.enqueue { await $0.store(data, tabID: id, url: url) }
      self.imagesDidChange.send(())
      completion?(result)
    }
  }

  /// Finish visible captures and queued writes before Chromium closes. The
  /// one-second operational deadline keeps disposable artwork from holding
  /// application termination indefinitely if the compositor stops replying.
  func prepareForTermination(sessions: [BrowserSession], completion: @escaping @MainActor () -> Void) {
    guard !draining else { return }
    for session in sessions where session.isSurfaceVisible { capture(session) }
    draining = true
    drainCompletion = completion
    drainTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.captures.removeAll()
      self?.completeDrain()
    }
    drainIfIdle()
  }

  private func drainIfIdle() {
    guard drainCompletion != nil, captures.isEmpty else { return }
    flushRecency()
    let pending = diskWork
    Task { [weak self] in
      await pending?.value
      self?.completeDrain()
    }
  }

  private func completeDrain() {
    guard let completion = drainCompletion else { return }
    drainCompletion = nil
    drainTimeout?.cancel()
    drainTimeout = nil
    completion()
  }

  private func recordAccess(to key: String) {
    guard !draining else { return }
    // A burst can visit more images than fit in memory. Flush before adding a
    // new identity rather than letting the pending batch grow without bound.
    if pendingRecency[key] == nil, pendingRecency.count >= images.countLimit {
      flushRecency()
    }
    pendingRecency[key] = Date()
    guard recencyFlush == nil else { return }
    recencyFlush = Task { [weak self] in
      try? await Task.sleep(for: Self.recencyFlushInterval)
      guard !Task.isCancelled else { return }
      self?.flushRecency()
    }
  }

  private func flushRecency() {
    recencyFlush?.cancel()
    recencyFlush = nil
    guard !pendingRecency.isEmpty else { return }
    let updates = pendingRecency
    pendingRecency.removeAll(keepingCapacity: true)
    appendDiskWork { await $0.touch(updates) }
  }

  private func enqueue(_ operation: @escaping @Sendable (PagePreviewStore) async -> Void) {
    // Apply recency before an operation that can evict or replace entries.
    flushRecency()
    appendDiskWork(operation)
  }

  private func appendDiskWork(_ operation: @escaping @Sendable (PagePreviewStore) async -> Void) {
    let preceding = diskWork
    diskWork = Task { [store] in
      await preceding?.value
      await operation(store)
    }
  }
}
