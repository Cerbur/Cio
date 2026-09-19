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

    // The address-field parser needs neither CEF nor a run loop, so it is
    // answered before Chromium is initialized.
    if NavigationInputProbe.isRequested() {
      NavigationInputProbe.run()
    }

    let runtime = ApplicationRuntime.shared
    if CommandLine.arguments.contains("--log-shutdown-timing") {
      runtime.enableShutdownTiming()
    }
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
    if CommandLine.arguments.contains("--navigation-self-test") {
      // Milestone 2 integration check. The result is this process's exit code.
      exit(NavigationSelfTest.run(runtime: runtime))
    }

    scheduleToolingHooksIfRequested(runtime: runtime)

    AppLog.app.info("entering the NSApplication run loop")
    // Runs the NSApplication run loop until the app terminates.
    NativeBrowserApp.main()
    AppLog.app.info("the NSApplication run loop returned")

    // Safety net for the path where the run loop returned without
    // -applicationShouldTerminate: having run (for example a failed launch).
    // It is a no-op after a normal termination, and it never runs CefShutdown
    // while a browser is still open.
    if runtime.hasLiveBrowsers {
      AppLog.cef.error("run loop returned with a live browser; requesting closure")
      runtime.requestBrowserClosure()
      if !runtime.hasLiveBrowsers {
        runtime.shutdownCEF()
      }
    } else {
      runtime.shutdownCEF()
    }
  }

  /// True when the process was launched by the milestone verification tooling.
  private static var isVerificationRun: Bool {
    CommandLine.arguments.contains("--cef-self-test")
      || CommandLine.arguments.contains("--browser-self-test")
      || CommandLine.arguments.contains("--navigation-self-test")
      || NavigationInputProbe.isRequested()
      || CommandLine.arguments.contains { $0.hasPrefix("--quit-after=") }
      || CommandLine.arguments.contains { $0.hasPrefix("--navigate-after=") }
      || CommandLine.arguments.contains("--wait-for-window")
      || CommandLine.arguments.contains { $0.hasPrefix("--terminate-in-pump-after=") }
      || CommandLine.arguments.contains("--focus-address-first")
      || CommandLine.arguments.contains("--log-shutdown-timing")
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

  // MARK: - Tooling hooks
  //
  // The milestone scripts drive the real application instead of a synthetic
  // window, so they need to be able to wait for something to *happen* rather
  // than guess a delay. These switches are inert unless they are passed:
  //
  //   --wait-for-window    do not start the --quit-after countdown until the
  //                        SwiftUI window exists (the first launch into a fresh
  //                        data directory spends a moment building Chromium's
  //                        profile)
  //   --navigate-after=N   navigate the live browser (BrowserBridge -loadURL: ->
  //                        CefFrame::LoadURL) N seconds later
  //   --navigate-wait      do not start the countdown until that navigation has
  //                        been requested

  /// What the tooling hook sequence is waiting for. Held in a static because
  /// the run loop timer that drives it must not capture @MainActor state
  /// (Swift 6 rejects sending it into the timer's closure).
  private enum ToolingPhase {
    /// Waiting for the SwiftUI window before the countdown starts.
    case waitingForWindow
    /// Waiting out --navigate-after before navigating.
    case waitingToNavigate
    /// The navigation has been requested; waiting out --quit-after.
    case waitingForQuitAfterNavigation
    /// No navigation requested; waiting out --quit-after.
    case countingDownToQuit
    case done
  }

  private static var toolingPhase = ToolingPhase.done
  private static var toolingNavigateDelay: TimeInterval?
  private static var toolingQuitDelay: TimeInterval = 0
  private static var toolingDeadline = Date.distantPast

  private static func scheduleToolingHooksIfRequested(runtime: ApplicationRuntime) {
    // "--terminate-in-pump-after=<seconds>" reproduces the Cmd+Q stack: it
    // requests termination from inside a CEF message pump call.
    let inPumpPrefix = "--terminate-in-pump-after="
    if let argument = CommandLine.arguments.first(where: { $0.hasPrefix(inPumpPrefix) }),
      let delay = TimeInterval(argument.dropFirst(inPumpPrefix.count)), delay > 0
    {
      runtime.armTerminateInPump(
        after: delay,
        focusAddressField: CommandLine.arguments.contains("--focus-address-first"))
    }

    let quitPrefix = "--quit-after="
    guard
      let quitArgument = CommandLine.arguments.first(where: { $0.hasPrefix(quitPrefix) }),
      let quitDelay = TimeInterval(quitArgument.dropFirst(quitPrefix.count)), quitDelay > 0
    else { return }

    let navigatePrefix = "--navigate-after="
    toolingNavigateDelay = CommandLine.arguments
      .first { $0.hasPrefix(navigatePrefix) }
      .flatMap { TimeInterval($0.dropFirst(navigatePrefix.count)) }
    toolingQuitDelay = quitDelay
    toolingDeadline = Date.distantPast

    let waitForWindow = CommandLine.arguments.contains("--wait-for-window")
    if waitForWindow {
      toolingPhase = .waitingForWindow
      AppLog.app.info("tooling: waiting for the SwiftUI window before starting the countdown")
    } else if let delay = toolingNavigateDelay {
      toolingPhase = .waitingToNavigate
      toolingDeadline = Date().addingTimeInterval(delay)
    } else {
      toolingPhase = .countingDownToQuit
      toolingDeadline = Date().addingTimeInterval(toolingQuitDelay)
    }

    // One repeating timer drives the whole sequence: wait for the window, then
    // for the navigation, then terminate. A repeating timer is used instead of
    // chained one-shot timers so that no @MainActor timer has to be captured by
    // another closure.
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated {
        toolingTick(runtime: runtime)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
  }

  private static func toolingTick(runtime: ApplicationRuntime) {
    switch toolingPhase {
    case .done:
      return

    case .waitingForWindow:
      guard runtime.didAppearInWindow else { return }
      AppLog.app.info("tooling: the SwiftUI window appeared")
      if let delay = toolingNavigateDelay {
        toolingPhase = .waitingToNavigate
        toolingDeadline = Date().addingTimeInterval(delay)
      } else {
        toolingPhase = .countingDownToQuit
        toolingDeadline = Date().addingTimeInterval(toolingQuitDelay)
      }

    case .waitingToNavigate:
      guard Date() >= toolingDeadline else { return }
      navigateForTooling(runtime: runtime)
      toolingPhase = .waitingForQuitAfterNavigation
      toolingDeadline = Date().addingTimeInterval(toolingQuitDelay)

    case .waitingForQuitAfterNavigation, .countingDownToQuit:
      guard Date() >= toolingDeadline else { return }
      toolingPhase = .done
      AppLog.app.info("tooling: requesting application termination")
      // Uses the real coordinator, but does not reproduce a native key stack.
      NSApp.terminate(nil)
    }
  }

  /// Performs a real main-frame navigation in the running application
  /// (BrowserBridge -loadURL: -> CefFrame::LoadURL), so the quit path can be
  /// exercised on a browser that has actually navigated.
  private static func navigateForTooling(runtime: ApplicationRuntime) {
    guard let url = URL(string: "https://example.com/") else { return }
    AppLog.navigation.info("tooling: navigating the live application")
    runtime.browserSession.load(url)
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
      // No browser exists in this mode, so there is nothing to close first.
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
