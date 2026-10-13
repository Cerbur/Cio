import AppKit
import CioEngine
import Foundation

/// Process-level regression for downloads outliving their source WebContents.
/// Runs in the real SwiftUI shell with a caller-provided loopback fixture.
@MainActor
enum DownloadCloseSelfTest {
  private static var driver: Driver?
  static func installIfRequested(runtime: ApplicationRuntime) {
    guard CommandLine.arguments.contains("--download-close-self-test")
            || CommandLine.arguments.contains("--download-library-self-test"),
          let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--download-close-url=") }),
          let url = URL(string: String(raw.dropFirst("--download-close-url=".count))),
          url.host == "127.0.0.1", ProcessInfo.processInfo.environment["CIO_DATA_DIR"] != nil
    else { return }
    runtime.onMainWindowAppeared = {
      driver = Driver(runtime: runtime, url: url)
      driver?.start()
    }
  }

  @MainActor
  private final class Driver {
    let runtime: ApplicationRuntime
    let url: URL
    var timer: Timer?
    let deadline = Date().addingTimeInterval(60)
    var started = false
    var closed = false
    var showedDownloads = false
    var libraryShownAt: Date?
    let preservesSource = CommandLine.arguments.contains("--download-library-self-test")
    init(runtime: ApplicationRuntime, url: URL) { self.runtime = runtime; self.url = url }
    func start() {
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.step() }
      }
    }
    func step() {
      if Date() > deadline { print("download-close: FAIL timeout"); fflush(stdout); exit(2) }
      if !started, let session = runtime.workspaceStore.selectedSession, session.hasFinishedFirstLoad {
        started = true
        session.startDownload(url)
      }
      guard let item = runtime.downloadManager.items.first else { return }
      if !showedDownloads, item.receivedBytes > 0, item.state == .downloading,
         (CommandLine.arguments.contains("--download-close-show-library") || preservesSource) {
        showedDownloads = true
        libraryShownAt = Date()
        runtime.showDownloads()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("download-close: Downloads opened during progress")
        fflush(stdout)
        return
      }
      // Allow the native progress control to render while the source remains
      // mounted. Closing immediately can conceal an appearance-resolution loop.
      if let libraryShownAt, Date().timeIntervalSince(libraryShownAt) < 2 { return }
      if !preservesSource, !closed, item.receivedBytes > 0, item.state == .downloading {
        closed = true
        print("download-close: source-close requested after progress")
        fflush(stdout)
        runtime.workspaceStore.closeSelectedTab()
        return
      }
      if (closed || preservesSource && showedDownloads), item.state == .completed {
        guard (preservesSource ? runtime.workspaceStore.tabs.count == 1 : runtime.workspaceStore.tabs.isEmpty),
              let destination = item.destinationURL,
              let bytes = try? Data(contentsOf: destination), bytes.count == 8388608,
              bytes.enumerated().allSatisfy({ $0.element == UInt8($0.offset % 251) }) else {
          print("download-close: FAIL source teardown or bytes"); fflush(stdout); exit(2)
        }
        print(preservesSource
          ? "download-library: PASS foreground panel and exact bytes with live source"
          : "download-close: PASS completion and exact bytes after source teardown")
        fflush(stdout)
        timer?.invalidate()
        NSApp.terminate(nil)
      } else if item.state == .failed || item.state == .cancelled {
        print("download-close: FAIL interrupted"); fflush(stdout); exit(2)
      }
    }
  }
}
