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

  /// How long termination waits for Chromium browsers to finish closing before
  /// CefShutdown() runs (ARCHITECTURE.md section 11).
  private static let browserShutdownTimeout: TimeInterval = 5.0

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
  func pumpMessageLoop() {
    CEFProcessHost.doMessageLoopWork()
  }

  // MARK: - Shutdown

  /// Called before termination: close every browser, wait for Chromium to
  /// finish destroying them, then stop pumping the message loop
  /// (ARCHITECTURE.md section 11).
  func prepareForTermination() {
    AppLog.app.info("application runtime prepared for termination")
    closeBrowserSessions()
    stopMessagePump()
    record("runtime:prepared-for-termination")
  }

  /// Shuts CEF down. Idempotent, and safe to call when CEF never started.
  func shutdownCEF() {
    guard !didShutDownCEF else { return }
    didShutDownCEF = true
    closeBrowserSessions()
    stopMessagePump()
    CEFProcessHost.shutdown()
    record("cef:shutdown(clean: \(!CEFProcessHost.isInitialized))")
    AppLog.cef.info("CEF shutdown requested")
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

  /// Closes every live browser and pumps CEF until Chromium reports them
  /// destroyed, so that CefShutdown() never runs with a browser still alive.
  private func closeBrowserSessions() {
    let open = liveSessions.filter { !$0.isClosed }
    guard !open.isEmpty else { return }

    AppLog.cef.info("closing \(open.count, privacy: .public) Chromium browser(s) before shutdown")
    for session in open {
      session.close()
    }

    let deadline = Date().addingTimeInterval(Self.browserShutdownTimeout)
    let started = Date()
    while liveSessions.contains(where: { !$0.isClosed }), Date() < deadline {
      pumpMessageLoop()
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let elapsed = Date().timeIntervalSince(started)
    AppLog.cef.info(
      "browser shutdown took \(Int(elapsed * 1000), privacy: .public) ms")

    if liveSessions.contains(where: { !$0.isClosed }) {
      record("browser:close-timeout")
      AppLog.cef.error("a Chromium browser did not close before the shutdown deadline")
    }
  }
}
