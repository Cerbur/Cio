//
//  ApplicationRuntime.swift
//  NativeBrowser
//
//  Application scoped runtime state. CEF's lifecycle belongs to the
//  application, not to any view (ARCHITECTURE.md section 40, constraint 8),
//  so it lives here and is owned by the process entry point.
//

import Foundation

/// Owns the CEF runtime for the whole application.
@MainActor
final class ApplicationRuntime: ObservableObject {
  /// Shared instance. The entry point creates it before the UI exists.
  static let shared = ApplicationRuntime()

  /// Mirrors CEFProcessHost state in a form the UI can render.
  enum CEFStatus: Equatable {
    case notInitialized
    case initialized(version: String)
    case failed(message: String)

    var isReady: Bool {
      if case .initialized = self { return true }
      return false
    }

  }

  /// CEF is pumped from the application's own run loop because the app owns
  /// the NSApplication run loop (SwiftUI) rather than CEF owning it.
  private static let messagePumpInterval: TimeInterval = 1.0 / 60.0

  /// Fallback deadline for termination: how long the Terminator waits for
  /// browsers to reach OnBeforeClose before proceeding anyway. It is a safety
  /// net, not part of the normal path - a browser normally closes in
  /// milliseconds (ARCHITECTURE.md section 11).
  static let browserShutdownTimeout: TimeInterval = 5.0

  /// Milestone 1 opens a single hard-coded page. Milestone 2 adds the command
  /// bar and Milestone 3 adds real tabs; --home-url is a development override
  /// used by the verification tooling.
  static let defaultHomeURL = URL(string: "https://www.google.com")!

  static var homeURL: URL {
    let prefix = "--home-url="
    if let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
      let url = URL(string: String(argument.dropFirst(prefix.count)))
    {
      return url
    }
    return defaultHomeURL
  }

  /// The single browser session of Milestone 1.
  let browserSession: BrowserSession

  /// Every live browser session. Milestone 3 replaces this with a session
  /// manager keyed by tab identifier, but shutdown already needs the registry
  /// because browsers must be closed before CefShutdown().
  private var liveSessions: [BrowserSession] = []
  private var onBrowserClosed: (() -> Void)?

  @Published private(set) var cefStatus: CEFStatus = .notInitialized

  /// Ordered lifecycle milestones. Verification modes print this trace so that
  /// "CEF initializes and shuts down cleanly" can be checked automatically.
  private(set) var lifecycleTrace: [String] = []

  private var messagePumpTimer: Timer?
  private var didShutDownCEF = false
  private var isTracingEnabled = false

  private init() {
    let session = BrowserSession(initialURL: Self.homeURL)
    browserSession = session
    liveSessions = [session]
    session.onLifecycleEvent = { [weak self] event in
      self?.record(event)
    }
  }

  /// Records a lifecycle milestone. Enabled by the verification modes.
  func beginLifecycleTrace() {
    isTracingEnabled = true
    lifecycleTrace.removeAll()
    record("runtime:main")
  }

  func record(_ milestone: String) {
    if milestone.hasPrefix("browser:closed") {
      onBrowserClosed?()
    }
    if milestone == "swiftui:main-window-appeared" {
      didAppearInWindow = true
    }
    guard isTracingEnabled else { return }
    lifecycleTrace.append(milestone)
  }

  /// True once the SwiftUI window has reported that it appeared.
  ///
  /// Recorded whether or not the lifecycle trace is enabled, so the tooling
  /// hooks can wait for the window instead of guessing how long launch takes.
  private(set) var didAppearInWindow = false

  /// Prints the recorded milestones to standard output. Used by
  /// Scripts/verify_milestone0.sh; it is not the app's observability mechanism
  /// (that is AppLog / OSLog).
  func emitLifecycleTrace() {
    guard isTracingEnabled, !lifecycleTrace.isEmpty else { return }
    let report = lifecycleTrace.map { "lifecycle: \($0)" }.joined(separator: "\n")
    FileHandle.standardOutput.write(Data((report + "\n").utf8))
  }

  // MARK: - Startup

  /// Initializes CEF for the browser process. Must run on the main thread
  /// before the application's run loop starts.
  func startCEF() {
    do {
      try CEFProcessHost.start()
      let version = CEFProcessHost.versionString ?? "unknown version"
      cefStatus = .initialized(version: version)
      record("cef:initialized")
      AppLog.cef.info("CEF initialized: \(version, privacy: .public)")
    } catch {
      cefStatus = .failed(message: error.localizedDescription)
      record("cef:failed(\(error.localizedDescription))")
      AppLog.cef.error(
        "CEF initialization failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Starts pumping CEF's message loop on the main run loop.
  func startMessagePump() {
    guard CEFProcessHost.isInitialized, messagePumpTimer == nil else { return }
    let timer = Timer.scheduledTimer(
      withTimeInterval: Self.messagePumpInterval, repeats: true
    ) { _ in
      MainActor.assumeIsolated {
        ApplicationRuntime.shared.pumpMessageLoop()
      }
    }
    timer.tolerance = Self.messagePumpInterval / 2
    RunLoop.main.add(timer, forMode: .common)
    messagePumpTimer = timer
    record("cef:message-pump-started")
    AppLog.cef.info("CEF message pump started")
  }

  /// Stops pumping CEF's message loop. Called before CEF shuts down so that no
  /// CEF call is made after CefShutdown().
  func stopMessagePump() {
    guard let timer = messagePumpTimer else { return }
    timer.invalidate()
    messagePumpTimer = nil
    record("cef:message-pump-stopped")
    AppLog.cef.info("CEF message pump stopped")
  }

  /// Drives CEF's message loop once. CEF callbacks are delivered from here.
  ///
  /// Tooling only: requests termination before entering CefDoMessageLoopWork.
  /// This checks the coordinator but does not reproduce a native Cmd+Q event
  /// dispatched from inside Chromium. Real-key testing remains necessary.
  func pumpMessageLoop() {
    if let deadline = terminateInPumpDeadline, deadline.timeIntervalSinceNow <= 0 {
      terminateInPumpDeadline = nil
      if focusAddressFieldForTooling {
        // Reproduces the reported hangs, which all happened while the native
        // address field owned the keyboard: the field editor is first
        // responder, so the Cmd+Q key equivalent is dispatched to the menu from
        // inside the text system rather than from the page.
        focusAddressFieldForTooling = false
        AppLog.app.info("tooling: focusing the address field before terminating")
        browserSession.requestAddressFieldFocus()
      }
      AppLog.app.info("tooling: requesting termination from inside the CEF message pump")
      NSApp.terminate(nil)
    }
    CEFProcessHost.doMessageLoopWork()
  }

  /// Deadline for the tooling hook above; nil unless it was requested.
  private var terminateInPumpDeadline: Date?

  /// Whether the tooling termination should focus the address field first.
  private var focusAddressFieldForTooling = false

  /// Arms the "--terminate-in-pump-after" tooling hook.
  func armTerminateInPump(after delay: TimeInterval, focusAddressField: Bool = false) {
    terminateInPumpDeadline = Date().addingTimeInterval(delay)
    focusAddressFieldForTooling = focusAddressField
  }

  // MARK: - Shutdown

  /// True once CefShutdown() has run. CefShutdown() must be called exactly once.
  var hasShutDownCEF: Bool { didShutDownCEF }

  /// True while a browser has not yet reached OnBeforeClose.
  var hasLiveBrowsers: Bool {
    liveSessions.contains { !$0.isClosed }
  }

  /// Requests browser closure without waiting for it.
  ///
  /// Called for ordinary browser teardown; application termination uses
  /// Terminator, which also waits for OnBeforeClose.
  func requestBrowserClosure() {
    let open = liveSessions.filter { !$0.isClosed }
    guard !open.isEmpty else {
      AppLog.cef.info("no live Chromium browser to close")
      return
    }
    markShutdownPhase("T1")
    AppLog.cef.info(
      "closing \(open.count, privacy: .public) Chromium browser(s); \(self.liveSessions.count, privacy: .public) live session(s)")
    for session in open {
      session.close()
    }
  }

  /// Releases every live browser's view (see BrowserBridge.releaseBrowserView).
  func releaseBrowserViews() {
    for session in liveSessions where !session.isClosed {
      session.releaseBrowserView()
    }
  }

  /// Shuts CEF down. Idempotent, and safe to call when CEF never started.
  ///
  /// MUST NOT be called while Chromium is on the stack: CefShutdown() re-enters
  /// CEF and trips a Chromium CHECK (see Terminator).
  func shutdownCEF() {
    guard !didShutDownCEF else { return }
    didShutDownCEF = true
    markShutdownPhase("T5")
    stopMessagePump()
    CEFProcessHost.shutdown()
    markShutdownPhase("T6")
    record("cef:shutdown(clean: \(!CEFProcessHost.isInitialized))")
    AppLog.cef.info("CEF shutdown requested")
  }

  // MARK: - Shutdown timing

  /// Whether shutdown timing is being recorded.
  var isShutdownTimingEnabled: Bool {
    shutdownTimingEnabled
  }

  private var shutdownTimingEnabled = false

  /// Enables shutdown timing. Called by BrowserMain for verification runs or
  /// when "--log-shutdown-timing" is passed, so normal runs pay nothing.
  func enableShutdownTiming() {
    shutdownTimingEnabled = true
    NBShutdownTimingEnable()
  }

  /// Starts the main-thread liveness detector (see ShutdownTiming.h) during
  /// termination, so a freeze shows up as a growing gap in the diagnostics.
  func startLivenessWatchdog() {
    guard shutdownTimingEnabled else { return }
    NBShutdownTimingStartLivenessWatchdog()
  }

  /// Records a timestamp for a shutdown phase on the shared monotonic epoch
  /// (see ShutdownTiming.h), so Swift, the Objective-C++ bridge and CEF's
  /// callbacks are all measured against one clock. Off unless enabled.
  func markShutdownPhase(_ phase: String) {
    guard shutdownTimingEnabled else { return }
    NBShutdownTimingMark(phase)
  }

  // MARK: - Termination

  /// Closes browsers and CEF after AppDelegate cancels the initial quit request.
  /// Cancellation lets the native event stack unwind; terminateLater would
  /// instead keep that stack alive beneath AppKit's nested modal loop.
  /// OnBeforeClose must arrive before CefShutdown. Completion asks AppKit to
  /// terminate again, this time with terminateNow.
  @MainActor
  final class Terminator {
    private let runtime: ApplicationRuntime
    private let onFinished: () -> Void
    private var isRunning = false
    private var didFinish = false
    private var didMarkFirstStep = false
    private var didRequestClosure = false
    private var pendingStep: Timer?
    private var timeoutTimer: Timer?
    private var deadline = Date.distantPast

    init(runtime: ApplicationRuntime, onFinished: @escaping () -> Void) {
      self.runtime = runtime
      self.onFinished = onFinished
    }

    /// Starts the termination sequence. Safe to call more than once.
    func start() {
      guard !isRunning, !didFinish else { return }
      isRunning = true
      deadline = Date().addingTimeInterval(ApplicationRuntime.browserShutdownTimeout)
      AppLog.app.info("termination: sequence starting")
      runtime.record("termination:started")
      runtime.startLivenessWatchdog()
      runtime.onBrowserClosed = { [weak self] in self?.scheduleStep() }
      let timer = Timer(timeInterval: ApplicationRuntime.browserShutdownTimeout,
                        repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.step() }
      }
      timeoutTimer = timer
      RunLoop.main.add(timer, forMode: .default)
      // Close only after the original terminate(_:) and key event return.
      scheduleStep()
    }

    /// Schedule on the normal run loop. A common-mode timer could run inside
    /// an unrelated modal/tracking loop while the triggering event is on-stack.
    private func scheduleStep() {
      pendingStep?.invalidate()
      let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.step()
        }
      }
      pendingStep = timer
      RunLoop.main.add(timer, forMode: .default)
    }

    private func step() {
      guard !didFinish else { return }
      if !didMarkFirstStep {
        didMarkFirstStep = true
        runtime.markShutdownPhase("firstStep")
      }
      // The close is requested here, on a clean stack, rather than inline in
      // -applicationShouldTerminate: (see start()).
      if !didRequestClosure {
        didRequestClosure = true
        runtime.requestBrowserClosure()
      }
      if !runtime.hasLiveBrowsers {
        AppLog.app.info("termination: every browser is closed")
        runtime.record("termination:browsers-closed")
        runtime.markShutdownPhase("T4")
        finish()
        return
      }
      if Date() >= deadline {
        // Explicit fallback policy: a browser that has not closed within the
        // shutdown budget is force-closed (force_close was already requested)
        // and reported, rather than leaving the application unable to quit.
        AppLog.cef.error("termination: a browser did not close before the deadline")
        runtime.record("termination:browser-close-timeout")
        finish()
        return
      }
      // OnBeforeClose schedules the next step. Do not busy-poll while CEF
      // and AppKit finish releasing the browser view.
    }

    private func finish() {
      guard !didFinish else { return }
      didFinish = true
      isRunning = false
      pendingStep?.invalidate()
      pendingStep = nil
      timeoutTimer?.invalidate()
      timeoutTimer = nil
      runtime.onBrowserClosed = nil

      // Never call CefShutdown() with a browser still open: Chromium asserts
      // (EXC_BREAKPOINT/SIGTRAP) and the application dies on quit instead of
      // exiting. That invariant is worth more than a tidy teardown, so if a
      // browser could not be closed the process is allowed to exit after
      // AppKit is told it may finish, and the condition is reported loudly
      // instead of being hidden.
      if runtime.hasLiveBrowsers {
        AppLog.cef.error(
          "termination: a browser is still open; skipping CefShutdown to avoid a Chromium abort")
        runtime.record("termination:skipped-cef-shutdown(browser-still-open)")
      } else {
        AppLog.cef.info("termination: shutting CEF down")
        runtime.shutdownCEF()
        AppLog.app.info("termination: CEF is down; requesting final termination")
      }
      runtime.record("termination:finished")
      onFinished()
    }
  }

  // MARK: - Browser sessions

  /// Registers an additional live session so termination closes it too.
  ///
  /// Milestone 3 replaces this with a session manager keyed by tab identifier;
  /// until then the only caller is the navigation self-test, which opens a
  /// second browser to check that a freshly created one is destroyed cleanly.
  func registerLiveSession(_ session: BrowserSession) {
    liveSessions.append(session)
    session.onLifecycleEvent = { [weak self] event in
      self?.record(event)
    }
  }
}
