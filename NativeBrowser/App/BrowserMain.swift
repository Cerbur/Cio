//
//  BrowserMain.swift
//  NativeBrowser
//
//  Process entry point.
//
//  Order matters here (ARCHITECTURE.md section 11):
//    1. hand the process off to CEF if it was launched as a sub-process,
//    2. load the CEF framework and initialize it,
//    3. start the SwiftUI/AppKit application,
//    4. shut CEF down after the run loop returns.
//

import AppKit
import Foundation

@main
@MainActor
enum BrowserMain {
  static func main() {
    let subprocessExitCode = CEFProcessHost.executeSubprocess()
    if subprocessExitCode >= 0 {
      // This process is a CEF sub-process and has already done its work.
      exit(subprocessExitCode)
    }

    let runtime = ApplicationRuntime.shared
    if isVerificationRun {
      // Records the startup/shutdown milestones that Scripts/verify_milestone0.sh
      // checks; it is not the app's logging mechanism (see AppLog).
      runtime.beginLifecycleTrace()
    }
    runtime.startCEF()

    if runSelfTestIfRequested(runtime: runtime) {
      return
    }
    if runBrowserSelfTestIfRequested(runtime: runtime) {
      return
    }

    scheduleAutomaticTerminationIfRequested()

    // Runs the NSApplication run loop until the app terminates.
    NativeBrowserApp.main()

    // Safety net: -applicationWillTerminate: normally shuts CEF down first.
    runtime.shutdownCEF()
  }

  /// True when the process was launched by the milestone verification tooling.
  private static var isVerificationRun: Bool {
    CommandLine.arguments.contains("--cef-self-test")
      || CommandLine.arguments.contains("--browser-self-test")
      || CommandLine.arguments.contains { $0.hasPrefix("--quit-after=") }
  }

  /// Milestone 1 integration check: builds the real window and container, loads
  /// the configured page, waits for Chromium to report the load finished, then
  /// closes the browser and shuts CEF down.
  ///
  /// Running "NativeBrowser --browser-self-test" exits 0 only when the page
  /// loaded, no navigation error was reported and the browser was destroyed.
  private static func runBrowserSelfTestIfRequested(runtime: ApplicationRuntime) -> Bool {
    guard CommandLine.arguments.contains("--browser-self-test") else { return false }

    let session = runtime.browserSession
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "NativeBrowser self-test"
    let container = ChromiumContainerView(frame: window.contentLayoutRect)
    container.autoresizingMask = [.width, .height]
    window.contentView = container
    // The browser view needs a window to render into; keep the test window
    // behind everything else.
    window.orderBack(nil)
    session.attach(to: container)

    // CEF is pumped from the application run loop, which the self-test drives
    // itself instead of starting SwiftUI.
    runtime.startMessagePump()

    let loadDeadline = Date().addingTimeInterval(45)
    while Date() < loadDeadline, !session.hasFinishedFirstLoad {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    let loaded = session.hasFinishedFirstLoad && session.lastErrorCode == nil
    print(
      "browser-self-test: loaded=\(loaded) title=\(session.title) url=\(session.url?.absoluteString ?? "")"
    )
    runtime.record("selftest:loaded=\(loaded)")

    // Resize check: the window, the AppKit container and the Chromium view must
    // all track each other (ARCHITECTURE.md section 9).
    let resizedSize = NSSize(width: 900, height: 620)
    window.setContentSize(resizedSize)
    let resizeDeadline = Date().addingTimeInterval(1.0)
    while Date() < resizeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let containerSize = container.bounds.size
    print(
      "browser-self-test: resized-container=\(Int(containerSize.width))x\(Int(containerSize.height))"
    )
    runtime.record(
      "selftest:resized=\(Int(containerSize.width))x\(Int(containerSize.height))")

    // Close the browser the same way the application does at termination:
    // request the close, pump, then let the runtime finish and shut CEF down.
    let closeStart = Date()
    session.close()
    let closeDeadline = Date().addingTimeInterval(5)
    while Date() < closeDeadline, !session.isClosed {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    window.close()
    runtime.shutdownCEF()

    let closed = session.isClosed
    let closeDuration = Date().timeIntervalSince(closeStart)
    print(
      "browser-self-test: browser-closed=\(closed) close-seconds=\(String(format: "%.2f", closeDuration))"
    )
    runtime.record("selftest:closed=\(closed)")
    runtime.emitLifecycleTrace()
    exit(loaded && closed ? 0 : 2)
  }

  /// Test hook: "--quit-after=<seconds>" terminates the application through the
  /// normal AppKit termination path, which exercises the CEF shutdown sequence.
  private static func scheduleAutomaticTerminationIfRequested() {
    let prefix = "--quit-after="
    guard
      let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
      let seconds = TimeInterval(argument.dropFirst(prefix.count)), seconds > 0
    else { return }

    AppLog.app.info("scheduling automatic termination in \(seconds, privacy: .public)s")
    let timer = Timer(timeInterval: seconds, repeats: false) { _ in
      MainActor.assumeIsolated {
        NSApp.terminate(nil)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
  }

  /// Headless CEF lifecycle check used by tooling. Running
  /// "NativeBrowser --cef-self-test" initializes CEF, pumps its message loop
  /// briefly, shuts CEF down and exits with 0 only if all of that succeeded.
  private static func runSelfTestIfRequested(runtime: ApplicationRuntime) -> Bool {
    guard CommandLine.arguments.contains("--cef-self-test") else { return false }

    let started = runtime.cefStatus.isReady
    AppLog.cef.info("CEF self-test starting (initialized: \(started, privacy: .public))")

    if started {
      runtime.startMessagePump()
      let deadline = Date().addingTimeInterval(2.0)
      while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      runtime.prepareForTermination()
      runtime.shutdownCEF()
    }

    let cleanShutdown = !CEFProcessHost.isInitialized
    AppLog.cef.info(
      "CEF self-test finished (initialized: \(started, privacy: .public), clean shutdown: \(cleanShutdown, privacy: .public))"
    )
    runtime.emitLifecycleTrace()
    exit(started && cleanShutdown ? 0 : 2)
  }
}
