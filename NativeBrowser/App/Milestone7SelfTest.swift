//
//  Milestone7SelfTest.swift
//  NativeBrowser
//
//  Real-CEF history/download integration driver used by
//  Scripts/verify_milestone7.sh. It deliberately reports only sanitized,
//  aggregate facts; the exact URLs stay in the isolated private database.
//

import AppKit
import Foundation

@MainActor
enum Milestone7SelfTest {
  private static let phasePrefix = "--milestone7-self-test="
  private static let basePrefix = "--m7-fixture-base-url="
  private static let failedPrefix = "--m7-failed-url="

  static func installIfRequested(runtime: ApplicationRuntime) -> Bool {
    guard let phase = CommandLine.arguments
      .first(where: { $0.hasPrefix(phasePrefix) })
      .map({ String($0.dropFirst(phasePrefix.count)) }) else {
      return false
    }
    run(runtime: runtime, phase: phase)
    return true
  }

  private static func run(runtime: ApplicationRuntime, phase: String) -> Never {
    let workspace = runtime.workspaceStore
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "NativeBrowser Milestone 7 self-test"
    let host = BrowserSurfaceHostView(frame: window.contentLayoutRect)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    window.orderBack(nil)
    workspace.attachSurfaceHost(host)

    guard let session = workspace.selectedSession,
      let baseURLString = argument(withPrefix: basePrefix),
      let baseURL = URL(string: baseURLString)
    else {
      print("m7-self-test: FAIL setup")
      runtime.shutdownCEF()
      exit(2)
    }

    runtime.startMessagePump()

    var failures = 0
    func check(_ condition: Bool, _ name: String) {
      if condition {
        print("m7-self-test: pass \(name)")
      } else {
        print("m7-self-test: FAIL \(name)")
        failures += 1
      }
    }

    let pageA = ApplicationRuntime.homeURL
    let pageB = baseURL.appendingPathComponent("page-b")
    let redirect = baseURL.appendingPathComponent("redirect")
    let download = baseURL.appendingPathComponent("download")
    let failedURL = argument(withPrefix: failedPrefix).flatMap(URL.init(string:))
      ?? URL(string: "http://127.0.0.1:9/m7-failed")!

    if phase == "seed" {
      let initialLoaded = waitUntil(timeout: 45) { session.hasFinishedFirstLoad }
      check(initialLoaded && session.lastErrorCode == nil, "real-cef-initial-page-load")

      check(navigate(session: session, to: pageB), "real-cef-page-b-load")
      check(navigate(session: session, to: pageA), "real-cef-page-a-revisit")
      check(navigate(session: session, to: redirect), "real-cef-redirect-load")

      check(downloadOnce(session: session, url: download, manager: runtime.downloadManager), "real-cef-download-completed")
      check(downloadOnce(session: session, url: download, manager: runtime.downloadManager), "real-cef-second-download-completed")

      let historyBeforeFailure = runtime.historyService.entries
      let failed = navigateExpectingFailure(session: session, to: failedURL)
      check(failed, "failed-network-load-observed")
      let historyAfterFailure = runtime.historyService.entries
      check(historyAfterFailure.count == historyBeforeFailure.count, "failed-load-excluded-from-history")

      let historyTitleSettled = waitUntil(timeout: 10) {
        runtime.historyService.entries.contains { $0.url == pageA && $0.title == "Page A" }
      }
      let pageAEntry = runtime.historyService.entries.first { $0.url == pageA }
      let pageBEntry = runtime.historyService.entries.first { $0.url == pageB }
      check(pageAEntry?.visitCount == 2, "history-visit-increment")
      check(historyTitleSettled, "history-title")
      check(pageBEntry != nil && pageBEntry?.visitCount == 2, "history-final-redirect-destination")
      check(!runtime.historyService.entries.contains { $0.url == redirect }, "history-does-not-store-provisional-redirect")

      let items = runtime.downloadManager.items
      check(items.count == 2, "download-item-identity")
      check(items.allSatisfy { $0.state == .completed }, "download-completed-state")
      check(items.allSatisfy { item in
        guard let destination = item.destinationURL else { return false }
        return destination.standardizedFileURL.path.hasPrefix(
          runtime.downloadManager.downloadsDirectoryURL.standardizedFileURL.path + "/")
      }, "download-destination-containment")
      check(items.compactMap(\.destinationURL).count == 2
        && Set(items.compactMap(\.destinationURL)).count == 2, "download-collision-safe-second-file")
      check(items.allSatisfy { item in
        guard let destination = item.destinationURL else { return false }
        return FileManager.default.fileExists(atPath: destination.path)
      }, "download-file-exists")
      let fileNames = Set(items.map(\.fileName))
      check(fileNames == ["fixture.bin", "fixture (1).bin"], "download-content-disposition-filenames")

      print("m7-self-test: history-entries=\(runtime.historyService.entries.count)")
      print("m7-self-test: downloads=\(items.count) bytes=\(items.map(\.receivedBytes).reduce(0, +))")
    } else if phase == "verify" {
      let persistedEntries = runtime.historyService.entries
      check(persistedEntries.contains { $0.url == pageA && $0.visitCount == 2 }, "history-db-persisted-visit-count")
      check(persistedEntries.contains { $0.url == pageA && $0.title == "Page A" }, "history-db-persisted-title")
      check(persistedEntries.contains { $0.url == pageB && $0.visitCount == 2 }, "history-db-persisted-redirect-result")
      check(!persistedEntries.contains { $0.url == failedURL }, "history-db-persisted-failed-load-exclusion")

      let loaded = waitUntil(timeout: 45) { session.hasFinishedFirstLoad }
      check(loaded && session.lastErrorCode == nil, "real-cef-relaunch-load")
      check(runtime.downloadManager.items.isEmpty, "download-list-is-process-memory-only")
    } else {
      check(false, "known-self-test-phase")
    }

    let closeStarted = Date()
    // Stop any residual page load before asking CEF to release the view. A real
    // download can still defer OnBeforeClose in this CEF build, so retain the
    // existing self-test-only view-release fallback below.
    session.stop()
    session.close(terminating: true)
    var closed = waitUntil(timeout: 5) { session.isClosed }
    if !closed {
      // The existing runtime diagnostic hook releases the native CEF view
      // without inventing a second browser owner. This is only a self-test
      // fallback for the attachment-navigation teardown quirk.
      runtime.sessionManager.releaseBrowserViews()
      closed = waitUntil(timeout: 10) { session.isClosed }
    }
    window.close()
    runtime.shutdownCEF()
    // If CEF deferred OnBeforeClose, CefShutdown drains the already-requested
    // close. The assertion is intentionally made after that clean shutdown so
    // the harness verifies the browser is not left live at process exit.
    if !closed {
      closed = waitUntil(timeout: 5) { session.isClosed }
    }
    check(closed, "clean-browser-shutdown")
    check(runtime.hasShutDownCEF && runtime.cefShutdownCount == 1, "cef-shutdown-once")
    print("m7-self-test: checks=\(phase) failures=\(failures) close-seconds=\(String(format: "%.2f", Date().timeIntervalSince(closeStarted)))")
    runtime.emitLifecycleTrace()
    exit(failures == 0 ? 0 : 2)
  }

  private static func navigate(session: BrowserSession, to url: URL) -> Bool {
    let previousCount = session.successfulMainFrameLoadCount
    session.load(url)
    return waitUntil(timeout: 45) {
      session.successfulMainFrameLoadCount > previousCount
        && session.lastErrorCode == nil
        && !session.isLoading
    }
  }

  private static func navigateExpectingFailure(session: BrowserSession, to url: URL) -> Bool {
    session.load(url)
    return waitUntil(timeout: 15) {
      session.lastErrorCode != nil && !session.isLoading
    }
  }

  private static func downloadOnce(
    session: BrowserSession,
    url: URL,
    manager: DownloadManager
  ) -> Bool {
    let existingItemIDs = Set(manager.items.map(\.id))
    session.startDownload(url)
    return waitUntil(timeout: 45) {
      manager.items.contains { item in
        !existingItemIDs.contains(item.id)
          && item.state == .completed
          && item.destinationURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
      }
    }
  }

  private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
  }

  private static func argument(withPrefix prefix: String) -> String? {
    CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
      .map { String($0.dropFirst(prefix.count)) }
  }
}
