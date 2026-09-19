//
//  ApplicationRuntime.swift
//  NativeBrowser
//
//  Application scoped runtime state. CEF's lifecycle belongs to the
//  application, not to any view (ARCHITECTURE.md section 40, constraint 8),
//  so it lives here and is owned by the process entry point.
//
//  Milestone 3 moved browser ownership from "one browserSession" to the
//  BrowserSessionManager: the runtime now owns exactly one manager, and the
//  manager owns the tabs and their sessions. Nothing here keeps a second
//  liveness registry - hasLiveBrowsers asks the manager, and the termination
//  coordinator is woken by a typed per-session callback rather than by parsing
//  a lifecycle string.
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
  /// milliseconds, and with several tabs they close in parallel rather than one
  /// after another (ARCHITECTURE.md section 11).
  static let browserShutdownTimeout: TimeInterval = 5.0

  /// Milestone 1 opened a single hard-coded page. Milestone 3 opens one tab with
  /// this URL at launch; --home-url is a development override used by the
  /// verification tooling.
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

  /// Owns every tab and every Chromium browser the application has open.
  let sessionManager: BrowserSessionManager

  @Published private(set) var cefStatus: CEFStatus = .notInitialized

  /// Ordered lifecycle milestones. Verification modes print this trace so that
  /// "CEF initializes and shuts down cleanly" can be checked automatically.
  private(set) var lifecycleTrace: [String] = []

  /// Typed notification that one browser session reached OnBeforeClose and was
  /// released. Set by the Terminator for the duration of the shutdown sequence;
  /// the callback carries the session, so the receiver always knows which
  /// browser closed (Milestone 3 section 7).
  var onLiveSessionDidClose: ((BrowserSession) -> Void)?

  private var messagePumpTimer: Timer?
  private var didShutDownCEF = false
  private var cefShutdownInvocations = 0
  private var isTracingEnabled = false

  private init() {
    let manager = BrowserSessionManager(initialTabURL: Self.homeURL)
    sessionManager = manager
    manager.onLifecycleEvent = { [weak self] event in
      self?.record(event)
    }
    manager.onLiveSessionDidClose = { [weak self] session in
      self?.onLiveSessionDidClose?(session)
    }
    // Mirrored so the SwiftUI scene - and therefore the menu commands built from
    // it - re-evaluate when the tab list, the selection or the selected tab's
    // navigation state changes.
    manager.onWillPublish = { [weak self] in
      self?.objectWillChange.send()
    }
  }

  /// Records a lifecycle milestone. Enabled by the verification modes.
  func beginLifecycleTrace() {
    isTracingEnabled = true
    lifecycleTrace.removeAll()
    record("runtime:main")
  }

  /// Records a lifecycle milestone.
  ///
  /// Diagnostics only. Milestone 3 removed the last piece of control flow that
  /// was driven by these strings, so recording one can no longer close a browser
  /// or release a session.
  func record(_ milestone: String) {
    guard isTracingEnabled else { return }
    lifecycleTrace.append(milestone)
  }

  /// Records that the SwiftUI window appeared.
  ///
  /// A typed call rather than a string comparison inside record(_:): the tooling
  /// hooks wait on the flag, not on the trace.
  func noteMainWindowAppeared() {
    didAppearInWindow = true
    record("swiftui:main-window-appeared")
  }

  /// True once the SwiftUI window has reported that it appeared.
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
        sessionManager.selectedSession?.requestAddressFieldFocus()
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

  /// How many times CefShutdown() actually ran. The multi-tab integration test
  /// asserts this is exactly 1.
  var cefShutdownCount: Int { cefShutdownInvocations }

  /// True while any browser has not yet reached OnBeforeClose, including the
  /// browsers whose tab has already left the sidebar. The manager owns the one
  /// and only registry, so this cannot disagree with what termination closes.
  var hasLiveBrowsers: Bool { sessionManager.hasLiveSessions }

  /// Requests browser closure without waiting for it.
  ///
  /// Called for ordinary browser teardown; application termination uses
  /// Terminator, which also waits for OnBeforeClose.
  func requestBrowserClosure() {
    guard sessionManager.hasLiveSessions else {
      AppLog.cef.info("no live Chromium browser to close")
      return
    }
    markShutdownPhase("T1")
    AppLog.cef.info(
      "closing \(self.sessionManager.liveSessionCount, privacy: .public) Chromium browser(s); every live session at once"
    )
    sessionManager.requestCloseAllForTermination()
  }

  /// Releases every live browser's view (see BrowserBridge.releaseBrowserView).
  ///
  /// A safety net for the case where CEF never delivers DoClose; the normal path
  /// is DoClose -> -[BrowserBridge completeClose].
  func releaseBrowserViews() {
    for session in sessionManager.liveSessions where !session.isClosed {
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
    cefShutdownInvocations += 1
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
      // Typed wake-up: the manager reports which session reached OnBeforeClose.
      // A close is never inferred from a lifecycle string.
      runtime.onLiveSessionDidClose = { [weak self] _ in self?.scheduleStep() }
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
      // -applicationShouldTerminate: (see start()). Every live browser is asked
      // to close in this one call; none is waited for before the next.
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
      // and AppKit finish releasing the browser views.
    }

    private func finish() {
      guard !didFinish else { return }
      didFinish = true
      isRunning = false
      pendingStep?.invalidate()
      pendingStep = nil
      timeoutTimer?.invalidate()
      timeoutTimer = nil
      runtime.onLiveSessionDidClose = nil

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
}
