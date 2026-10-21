//
//  ApplicationRuntime.swift
//  Cio
//
//  Application scoped runtime state. Chromium's lifecycle belongs to the
//  application, not to any view (ARCHITECTURE.md section 40, constraint 8),
//  so it lives here and is owned by the process entry point.
//
//  Milestone 4 separates pure workspace policy from Chromium runtime policy:
//  the runtime owns one BrowserWorkspaceStore, which owns one
//  BrowserSessionManager. Nothing here keeps a second liveness registry -
//  hasLiveBrowsers asks both the workspace manager and native Chrome UI host. The
//  termination coordinator is woken by a typed per-session callback rather
//  than by parsing a lifecycle string.
//

import CioChromium
import CioEngine
import CioModel
import Combine
import CioUI
import Foundation
import AppKit

/// Owns the Chromium runtime for the whole application.
@MainActor
final class ApplicationRuntime: ObservableObject {
  /// Shared instance. The entry point creates it before the UI exists.
  static let shared = ApplicationRuntime()

  /// Mirrors ChromiumProcessHost state in a form the UI can render.
  enum EngineStatus: Equatable {
    case notInitialized
    case initialized(version: String)
    case failed(message: String)

    var isReady: Bool {
      if case .initialized = self { return true }
      return false
    }

  }

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

  /// Owns all Spaces, tabs, selection policy and the runtime manager for the
  /// single application window.
  let workspaceStore: BrowserWorkspaceStore
  lazy var recentTabSwitcher = RecentTabSwitcherCoordinator(workspace: workspaceStore)

  /// Owns only durable workspace file IO. The domain projection remains in the
  /// workspace store and Chromium objects never cross this boundary.
  let sessionStore: SessionStore

  /// Compatibility projection for application lifecycle tooling. Runtime
  /// ownership remains inside `workspaceStore`; this is not a second owner.
  var sessionManager: BrowserSessionManager { workspaceStore.sessionManager }

  /// History and downloads are application-global concerns, independent of
  /// Spaces, tabs and runtime session lifetime.
  let historyService: HistoryService
  let downloadManager: DownloadManager

  typealias InternalBrowserPanel = BrowserInternalPanel

  /// The selected internal library is presented in the main window while the
  /// stable Chromium host remains mounted behind it.
  @Published var presentedInternalPanel: InternalBrowserPanel?


  // Stable composition projection; all state and publishers remain Runtime-owned.
  lazy var uiContext = BrowserUIContext(
    objectWillChange: objectWillChange,
    workspaceStore: workspaceStore,
    historyService: historyService,
    downloadManager: downloadManager,
    surfaceDriver: sessionManager,
    presentedInternalPanelPublisher: $presentedInternalPanel.eraseToAnyPublisher(),
    getPresentedInternalPanel: { [weak self] in self?.presentedInternalPanel },
    setPresentedInternalPanel: { [weak self] in self?.presentedInternalPanel = $0 },
    showHistory: { [weak self] in self?.showHistory() },
    showDownloads: { [weak self] in self?.showDownloads() },
    dismissSpotlight: { [weak self] in self?.dismissSpotlight() },
    performSpotlightAction: { [weak self] in self?.performSpotlightAction($0) },
    noteMainWindowAppeared: { [weak self] in self?.noteMainWindowAppeared() })

  @Published private(set) var engineStatus: EngineStatus = .notInitialized

  /// Ordered lifecycle milestones. Verification modes print this trace so that
  /// "Chromium initializes and shuts down cleanly" can be checked automatically.
  private(set) var lifecycleTrace: [String] = []

  /// Typed notification that one browser session reached OnBeforeClose and was
  /// released. Set by the Terminator for the duration of the shutdown sequence;
  /// the callback carries the session, so the receiver always knows which
  /// browser closed (Milestone 3 section 7).
  var onLiveSessionDidClose: ((BrowserSession) -> Void)?
  private var onChromeSettingsDidClose: (() -> Void)?

  /// Optional launch-driver hook used by the direct browser self-test. It
  /// fires only after the real SwiftUI window and stable surface host exist.
  var onMainWindowAppeared: (() -> Void)?

  private var nativeActionObservations: Set<AnyCancellable> = []
  private let extensionConfirmationCoordinator = ExtensionConfirmationCoordinator()
  private let messagePumpDriver = BrowserEngineRunLoopDriver()
  private var terminateInPumpTimer: Timer?
  private var terminationWatchdogTimer: Timer?
  private var terminationWatchdogStartedAt: Date?
  private var didShutDownBrowserEngine = false
  private var engineShutdownInvocations = 0
  private var isTracingEnabled = false
  private var persistenceFailurePresented = false

  private init() {
    let sessionStore = SessionStore()
    self.sessionStore = sessionStore
    self.historyService = HistoryService()
    self.downloadManager = DownloadManager()
    let store = BrowserWorkspaceStore(
      initialTabURL: Self.homeURL,
      sessionStore: sessionStore)
    workspaceStore = store
    store.onPictureInPictureActivation = { [weak self] in
      self?.presentedInternalPanel = nil
    }
    store.onPersistenceFailure = { [weak self] in self?.presentPersistenceFailure() }
    NotificationCenter.default.publisher(for: Notification.Name("CioOpenChromeSettings"))
      .sink { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self, let url = notification.object as? URL,
                !self.workspaceStore.isTerminating else { return }
          self.presentedInternalPanel = nil
          self.workspaceStore.createTab(url: url, title: "设置")
        }
      }.store(in: &nativeActionObservations)
    NotificationCenter.default.publisher(for: Notification.Name("CioOpenExtensionManager"))
      .sink { [weak self] _ in MainActor.assumeIsolated {
        self?.openExtensionsPage()
      }}.store(in: &nativeActionObservations)
    NotificationCenter.default.publisher(for: Notification.Name("CioFocusAddress"))
      .sink { [weak self] _ in MainActor.assumeIsolated {
        self?.workspaceStore.selectedSession?.requestAddressFieldFocus()
      }}.store(in: &nativeActionObservations)
    NotificationCenter.default.publisher(for: Notification.Name("CioShowTabSearch"))
      .sink { [weak self] _ in MainActor.assumeIsolated {
        self?.workspaceStore.presentSpotlight()
      }}.store(in: &nativeActionObservations)
    NotificationCenter.default.publisher(for: Notification.Name("CioBookmarkURL"))
      .sink { [weak self] _ in MainActor.assumeIsolated {
        guard let self, let id = self.workspaceStore.selectedTabID else { return }
        NotificationCenter.default.post(name: .browserToggleSpacePin, object: self.workspaceStore,
                                        userInfo: ["tabID": id])
      }}.store(in: &nativeActionObservations)
    store.onLifecycleEvent = { [weak self] event in
      self?.record(event)
    }
    store.sessionManager.onLiveSessionDidClose = { [weak self] session in
      self?.onLiveSessionDidClose?(session)
    }
    store.sessionManager.onMainFrameLoadFinished = { [weak self] session, url in
      guard let self else { return }
      self.historyService.recordVisit(url: url, title: session.title)
    }
    store.sessionManager.onTitleChanged = { [weak self] session in
      guard let self, let url = session.url else { return }
      // OnTitleChange can arrive before OnLoadEnd. The session's current main
      // frame URL is therefore the in-flight committed candidate; using the
      // previous successful URL would rename the page that was just left.
      // BrowserSession suppresses this callback for Chromium's error document.
      self.historyService.updateTitle(for: url, title: session.title)
    }
    store.sessionManager.onDownloadRequested = {
      [weak self] _, downloadID, sourceURL, suggestedFileName, metadata in
      guard let self else { return "" }
      guard let destination = self.downloadManager.prepareDownload(
        downloadID: downloadID,
        sourceURL: sourceURL,
        suggestedFileName: suggestedFileName,
        metadata: metadata)
      else {
        self.downloadManager.recordFailedDownload(
          downloadID: downloadID,
          sourceURL: sourceURL,
          suggestedFileName: suggestedFileName,
          metadata: metadata)
        return ""
      }
      return destination.path
    }
    NotificationCenter.default.publisher(for: Notification.Name("CioDownloadUpdated"))
      .sink { [weak self] notification in MainActor.assumeIsolated {
        self?.receiveDownloadUpdate(notification.userInfo)
      }}.store(in: &nativeActionObservations)
  }

  private func receiveDownloadUpdate(_ values: [AnyHashable: Any]?) {
    guard let values, let id = values["identifier"] as? NSNumber,
          let rawURL = values["url"] as? String, let url = URL(string: rawURL),
          let state = values["state"] as? NSNumber else { return }
    let total = (values["total"] as? NSNumber)?.int64Value ?? 0
    let path = values["destination"] as? String ?? ""
    let original = values["originalURL"] as? String ?? ""
    downloadManager.update(
      downloadID: id.uint32Value, sourceURL: url,
      suggestedFileName: values["name"] as? String ?? "download",
      metadata: DownloadMetadata(
        cefSuggestedFileName: values["suggestedName"] as? String ?? "",
        contentDisposition: values["contentDisposition"] as? String ?? "",
        mimeType: values["mimeType"] as? String ?? "",
        originalURL: URL(string: original)),
      destinationURL: path.isEmpty ? nil : URL(fileURLWithPath: path),
      receivedBytes: (values["received"] as? NSNumber)?.int64Value ?? 0,
      totalBytes: total > 0 ? total : nil,
      isInProgress: state.intValue == 0, isComplete: state.intValue == 1,
      isCancelled: state.intValue == 2, isInterrupted: state.intValue == 3,
      failureReason: (values["interruptReason"] as? NSNumber)?.intValue)
  }

  private var pendingExternalURLs: [URL] = []

  func openExternalURLs(_ urls: [URL]) {
    guard !workspaceStore.isTerminating else { return }
    pendingExternalURLs.append(contentsOf: urls.filter { ExternalWebURL.accepts($0) })
    guard didAppearInWindow else { return }
    drainExternalURLs()
  }

  private func drainExternalURLs() {
    guard !workspaceStore.isTerminating else { return }
    let urls = pendingExternalURLs
    pendingExternalURLs.removeAll()
    guard !urls.isEmpty else { return }
    presentedInternalPanel = nil
    workspaceStore.dismissSpotlight(focusPage: false)
    for url in urls { _ = workspaceStore.createTab(url: url) }
    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func showHistory() {
    workspaceStore.selectedSession?.blur()
    presentedInternalPanel = .history
  }

  func showDownloads() {
    workspaceStore.selectedSession?.blur()
    presentedInternalPanel = .downloads
  }

  func openExtensionsPage(store: Bool = false) {
    guard engineStatus.isReady, !workspaceStore.isTerminating,
          let url = URL(string: store ? "https://chromewebstore.google.com/" : "chrome://extensions/")
    else { return }
    presentedInternalPanel = nil
    workspaceStore.dismissSpotlight(focusPage: false)
    workspaceStore.createTab(url: url, title: store ? "Chrome 应用商店" : "扩展程序")
  }

  func openPasswordsPage() {
    guard engineStatus.isReady, !workspaceStore.isTerminating,
          let url = URL(string: "chrome://password-manager/passwords") else { return }
    presentedInternalPanel = nil
    workspaceStore.dismissSpotlight(focusPage: false)
    workspaceStore.createTab(url: url, title: "密码")
  }

  func toggleSpotlight() {
    if workspaceStore.isSpotlightPresented {
      dismissSpotlight()
    } else {
      workspaceStore.presentSpotlight()
    }
  }

  func dismissSpotlight() {
    workspaceStore.dismissSpotlight(focusPage: presentedInternalPanel == nil)
  }

  func performSpotlightAction(_ action: SpotlightAction) {
    guard workspaceStore.isSpotlightPresented else { return }
    switch action {
    case .openTab(let url):
      presentedInternalPanel = nil
      workspaceStore.submitSpotlight(opening: url)
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
    guard !didAppearInWindow else { return }
    didAppearInWindow = true
    record("swiftui:main-window-appeared")
    // Native Chromium can finish AppKit startup before SwiftUI installs our
    // application delegate. Window mounting is the reliable host boundary;
    // startMessagePump is idempotent when didFinishLaunching also arrives.
    startMessagePump()
    MainMenuDump.claimCloseTabShortcut()
    // AppKit may choose the first native NSTextField as the initial responder
    // while SwiftUI installs the toolbar. The browser surface is the launch
    // target, so explicitly complete the initial hand-off once the real
    // window exists. Subsequent address-field focus remains user-controlled.
    workspaceStore.selectedSession?.focusPage()
    drainExternalURLs()
    onMainWindowAppeared?()
    presentWorkspaceRecovery()
    if sessionStore.recoveryStatus == .none, workspaceStore.persistenceFailed {
      presentPersistenceFailure()
    }
  }

  private func presentWorkspaceRecovery() {
    guard sessionStore.recoveryStatus != .none, let window = NSApp.mainWindow else { return }
    let alert = NSAlert()
    alert.messageText = sessionStore.recoveryStatus == .restoredBackup
      ? "已从备份恢复工作区" : "无法恢复上次工作区"
    alert.informativeText = sessionStore.recoveryStatus == .restoredBackup
      ? "已恢复最近一份可用备份。最近的部分操作可能未包含在备份中，损坏的原文件已保留。"
      : "工作区和备份均无法读取，已打开新工作区。原文件已保留，可在资料目录中找回。"
    alert.addButton(withTitle: "继续")
    alert.addButton(withTitle: "查看资料目录")
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertSecondButtonReturn, let self {
        NSWorkspace.shared.open(self.sessionStore.sessionFileURL.deletingLastPathComponent())
      }
    }
  }

  private func presentPersistenceFailure() {
    guard !persistenceFailurePresented, !workspaceStore.isTerminating else { return }
    // A save can originate inside a Chromium callback. Present after that stack unwinds.
    persistenceFailurePresented = true
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = NSApp.mainWindow else {
        self?.persistenceFailurePresented = false
        return
      }
      let alert = NSAlert()
      alert.messageText = "工作区尚未保存"
      alert.informativeText = "请检查资料目录的可用空间和访问权限。当前标签页仍然保留在窗口中。"
      alert.addButton(withTitle: "重试")
      alert.addButton(withTitle: "查看资料目录")
      alert.addButton(withTitle: "稍后")
      alert.beginSheetModal(for: window) { [weak self] response in
        guard let self else { return }
        self.persistenceFailurePresented = false
        if response == .alertFirstButtonReturn {
          self.workspaceStore.flushSessionPersistence()
        } else if response == .alertSecondButtonReturn {
          NSWorkspace.shared.open(self.sessionStore.sessionFileURL.deletingLastPathComponent())
        }
      }
    }
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

  /// Initializes Chromium for the browser process. Must run on the main thread
  /// before the application's run loop starts.
  func startBrowserEngine() {
    do {
      try ChromiumProcessHost.start()
      let version = ChromiumProcessHost.versionString ?? "unknown version"
      engineStatus = .initialized(version: version)
      record("cef:initialized")
      AppLog.cef.info(
        "Browser engine initialized: \(ChromiumProcessHost.backendIdentifier, privacy: .public) interface=\(CioChromiumInterfaceVersion, privacy: .public) \(version, privacy: .public)")
    } catch {
      engineStatus = .failed(message: error.localizedDescription)
      record("cef:failed(\(error.localizedDescription))")
      AppLog.cef.error(
        "CEF initialization failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Drains Chromium before AppKit sleeps. Chromium's native CF sources and
  /// delayed-task deadlines wake the host; idle pages need no polling timer.
  func startMessagePump() {
    guard ChromiumProcessHost.isInitialized, !messagePumpDriver.isRunning else { return }
    messagePumpDriver.start { [weak self] in
      self?.pumpMessageLoop()
    }
    record("cef:message-pump-started")
    AppLog.cef.info("Chromium event-driven message pump started")
  }

  /// Stops pumping Chromium's message loop. Called before Chromium shuts down so that no
  /// Chromium call is made after native engine shutdown.
  func stopMessagePump() {
    terminateInPumpTimer?.invalidate()
    terminateInPumpTimer = nil
    guard messagePumpDriver.isRunning else { return }
    messagePumpDriver.stop()
    record("cef:message-pump-stopped")
    AppLog.cef.info("CEF message pump stopped")
  }

  /// Drives Chromium's message loop once, delivering callbacks before AppKit sleeps.
  ///
  /// Tooling only: requests termination before entering the native task pump.
  /// This checks the coordinator but does not reproduce a native Cmd+Q event
  /// dispatched from inside Chromium. Real-key testing remains necessary.
  func pumpMessageLoop() {
    guard ChromiumProcessHost.isInitialized, !isPumpingBrowserEngine else { return }
    isPumpingBrowserEngine = true
    defer {
      isPumpingBrowserEngine = false
      let completion = onBrowserPumpReturned
      onBrowserPumpReturned = nil
      completion?()
    }
    if let deadline = terminateInPumpDeadline, deadline.timeIntervalSinceNow <= 0 {
      terminateInPumpDeadline = nil
      if focusAddressFieldForTooling {
        // Reproduces the reported hangs, which all happened while the native
        // address field owned the keyboard: the field editor is first
        // responder, so the Cmd+Q key equivalent is dispatched to the menu from
        // inside the text system rather than from the page.
        focusAddressFieldForTooling = false
        AppLog.app.info("tooling: focusing the address field before terminating")
        workspaceStore.selectedSession?.requestAddressFieldFocus()
      }
      AppLog.app.info("tooling: requesting termination from inside the CEF message pump")
      NSApp.terminate(nil)
    }
    ChromiumProcessHost.doMessageLoopWork()
  }

  private var isPumpingBrowserEngine = false
  private var onBrowserPumpReturned: (() -> Void)?

  /// Deadline for the tooling hook above; nil unless it was requested.
  private var terminateInPumpDeadline: Date?

  /// Whether the tooling termination should focus the address field first.
  private var focusAddressFieldForTooling = false

  /// Arms the "--terminate-in-pump-after" tooling hook.
  func armTerminateInPump(after delay: TimeInterval, focusAddressField: Bool = false) {
    terminateInPumpDeadline = Date().addingTimeInterval(delay)
    focusAddressFieldForTooling = focusAddressField
    // This diagnostic previously piggybacked on the production polling timer.
    // Wake only at its requested deadline, including when the browser is idle.
    terminateInPumpTimer?.invalidate()
    let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.pumpMessageLoop() }
    }
    terminateInPumpTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  // MARK: - Shutdown

  /// True once Chromium has shut down. Shutdown must run exactly once.
  var hasShutDownBrowserEngine: Bool { didShutDownBrowserEngine }

  /// How many times native engine shutdown actually ran. The multi-tab integration test
  /// asserts this is exactly 1.
  var engineShutdownCount: Int { engineShutdownInvocations }

  /// True while any browser has not yet reached OnBeforeClose, including the
  /// browsers whose tab has already left the sidebar, and native Chrome UI
  /// windows owned by the process host.
  var hasLiveBrowsers: Bool {
    workspaceStore.hasLiveSessions || ChromiumProcessHost.hasLiveChromeSettingsBrowsers
  }

  /// Requests browser closure without waiting for it.
  ///
  /// Called for ordinary browser teardown; application termination uses
  /// Terminator, which also waits for OnBeforeClose.
  func requestBrowserClosure() {
    // Persist the durable domain graph before any live Chromium object starts
    // closing. Lazy tabs have no runtime and therefore need no synthetic close.
    workspaceStore.flushSessionPersistence()
    ChromiumProcessHost.closeChromeSettings { [weak self] in
      MainActor.assumeIsolated { self?.onChromeSettingsDidClose?() }
    }
    guard workspaceStore.hasLiveSessions else {
      AppLog.cef.info("no live Chromium browser to close")
      return
    }
    markShutdownPhase("T1")
    AppLog.cef.info(
      "closing \(self.workspaceStore.liveSessionCount, privacy: .public) Chromium browser(s); every live session at once"
    )
    workspaceStore.requestCloseAllForTermination()
  }

  /// Shuts Chromium down. Idempotent, and safe to call when Chromium never started.
  ///
  /// MUST NOT be called while Chromium is on the stack: native engine shutdown re-enters
  /// Chromium and trips a Chromium CHECK (see Terminator).
  @discardableResult
  func shutdownBrowserEngine() -> Bool {
    guard !didShutDownBrowserEngine else { return true }
    guard !isPumpingBrowserEngine else { return false }
    guard !hasLiveBrowsers else {
      // This is a hard safety boundary. A timer, a missing callback or a
      // returning NSApplication loop must never turn a live-browser condition
      // into native engine shutdown; the caller must keep pumping until OnBeforeClose.
      record("cef:shutdown-refused(live=\(workspaceStore.liveSessionCount))")
      AppLog.cef.error(
        "refusing CefShutdown while \(self.workspaceStore.liveSessionCount, privacy: .public) browser session(s) remain live")
      return false
    }
    didShutDownBrowserEngine = true
    engineShutdownInvocations += 1
    markShutdownPhase("T5")
    stopMessagePump()
    ChromiumProcessHost.shutdown()
    markShutdownPhase("T6")
    record("cef:shutdown(clean: \(!ChromiumProcessHost.isInitialized))")
    AppLog.cef.info("CEF shutdown requested")
    return true
  }

  /// Historical M7 diagnostic compatibility for deferred closes after downloads.
  /// This is deliberately limited to that diagnostic: production termination must use
  /// `shutdownBrowserEngine()`, which refuses to cross the live-session boundary.
  @discardableResult
  func drainDeferredBrowserCloseForM7SelfTest() -> Bool {
    guard !didShutDownBrowserEngine else { return true }
    guard CommandLine.arguments.contains(where: {
      $0 == "--milestone7-self-test=seed" || $0 == "--milestone7-self-test=verify"
    }) else {
      return false
    }
    guard workspaceStore.isTerminating, workspaceStore.hasLiveSessions else {
      return shutdownBrowserEngine()
    }

    record("cef:self-test-deferred-close-drain(live=\(workspaceStore.liveSessionCount))")
    didShutDownBrowserEngine = true
    engineShutdownInvocations += 1
    markShutdownPhase("T5")
    stopMessagePump()
    ChromiumProcessHost.shutdown()
    markShutdownPhase("T6")
    record("cef:shutdown(clean: \(!ChromiumProcessHost.isInitialized))")
    AppLog.cef.info("CEF shutdown requested by the M7 deferred-close diagnostic")
    return true
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

  /// Starts non-destructive production diagnostics during termination. The
  /// watchdog reports a stuck/slow close but never forces native engine shutdown.
  func startLivenessWatchdog() {
    stopLivenessWatchdog()
    let startedAt = Date()
    terminationWatchdogStartedAt = startedAt
    let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let startedAt = self.terminationWatchdogStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        AppLog.cef.warning(
          "termination watchdog: waiting for browser close callbacks live=\(self.workspaceStore.liveSessionCount, privacy: .public) elapsed=\(elapsed, privacy: .public)s")
      }
    }
    terminationWatchdogTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    if shutdownTimingEnabled {
      NBShutdownTimingStartLivenessWatchdog()
    }
  }

  func stopLivenessWatchdog() {
    terminationWatchdogTimer?.invalidate()
    terminationWatchdogTimer = nil
    terminationWatchdogStartedAt = nil
    if shutdownTimingEnabled {
      NBShutdownTimingStopLivenessWatchdog()
    }
  }

  /// Records a timestamp for a shutdown phase on the shared monotonic epoch
  /// (see ShutdownTiming.h), so Swift, the Objective-C++ bridge and Chromium's
  /// callbacks are all measured against one clock. Off unless enabled.
  func markShutdownPhase(_ phase: String) {
    guard shutdownTimingEnabled else { return }
    NBShutdownTimingMark(phase)
  }

  // MARK: - Termination

  /// Closes browsers and Chromium after AppDelegate cancels the initial quit request.
  /// Cancellation lets the native event stack unwind; terminateLater would
  /// instead keep that stack alive beneath AppKit's nested modal loop.
  /// OnBeforeClose must arrive before native engine shutdown. Completion asks AppKit to
  /// terminate again, this time with terminateNow.
  @MainActor
  final class Terminator {
    private let runtime: ApplicationRuntime
    private let onFinished: () -> Void
    private var isRunning = false
    private var didFinish = false
    private var didMarkFirstStep = false
    private var didRequestClosure = false
    private var didRequestPreviewFlush = false
    private var didCompletePreviewFlush = false
    private var didRequestCookieFlush = false
    private var didCompleteCookieFlush = false
    private var pendingStep: Timer?

    init(runtime: ApplicationRuntime, onFinished: @escaping () -> Void) {
      self.runtime = runtime
      self.onFinished = onFinished
    }

    /// Starts the termination sequence. Safe to call more than once.
    func start() {
      guard !isRunning, !didFinish else { return }
      isRunning = true
      AppLog.app.info("termination: sequence starting")
      runtime.record("termination:started")
      runtime.startLivenessWatchdog()
      // Typed wake-up: the manager reports which session reached OnBeforeClose.
      // A close is never inferred from a lifecycle string.
      runtime.onLiveSessionDidClose = { [weak self] _ in self?.scheduleStep() }
      runtime.onChromeSettingsDidClose = { [weak self] in self?.scheduleStep() }
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
      // Chromium's macOS pump can dispatch native timers/events. A timer is
      // not proof that its stack has unwound: wait for the outer pump return.
      if runtime.isPumpingBrowserEngine {
        runtime.onBrowserPumpReturned = { [weak self] in self?.scheduleStep() }
        return
      }
      if !didMarkFirstStep {
        didMarkFirstStep = true
        runtime.markShutdownPhase("firstStep")
      }
      if !didRequestPreviewFlush {
        didRequestPreviewFlush = true
        runtime.workspaceStore.pagePreviews.prepareForTermination(sessions: runtime.workspaceStore.liveSessions) { [weak self] in
          self?.didCompletePreviewFlush = true
          self?.scheduleStep()
        }
        return
      }
      guard didCompletePreviewFlush else { return }
      // The close is requested here, on a clean stack, rather than inline in
      // -applicationShouldTerminate: (see start()). Every live browser is asked
      // to close in this one call; none is waited for before the next.
      if !didRequestClosure {
        didRequestClosure = true
        runtime.requestBrowserClosure()
      }
      if !runtime.hasLiveBrowsers {
        if !didRequestCookieFlush {
          didRequestCookieFlush = true
          runtime.record("termination:cookie-flush-started")
          ChromiumProcessHost.flushCookies { [weak self] success in
            MainActor.assumeIsolated {
              guard let self else { return }
              if !success {
                AppLog.cef.error("Profile, password or cookie persistence could not be completed")
              }
              self.didCompleteCookieFlush = true
              self.runtime.record(success ? "termination:cookies-flushed" : "termination:cookie-flush-failed")
              if success { self.runtime.record("termination:password-writes-drained") }
              self.scheduleStep()
            }
          }
          return
        }
        guard didCompleteCookieFlush else { return }
        AppLog.app.info("termination: every browser is closed")
        runtime.record("termination:browsers-closed")
        runtime.markShutdownPhase("T4")
        finish()
        return
      }
      // OnBeforeClose schedules the next step. Do not busy-poll while Chromium
      // and AppKit finish releasing the browser views.
    }

    private func finish() {
      guard !didFinish else { return }
      guard !runtime.hasLiveBrowsers else {
        // A completion callback can never be inferred from a timer. If a
        // future refactor reaches this method too early, wait for the typed
        // close notification just as step() does.
        scheduleStep()
        return
      }
      guard runtime.shutdownBrowserEngine() else {
        scheduleStep()
        return
      }
      didFinish = true
      isRunning = false
      pendingStep?.invalidate()
      pendingStep = nil
      runtime.onLiveSessionDidClose = nil
      runtime.onChromeSettingsDidClose = nil
      runtime.stopLivenessWatchdog()

      AppLog.cef.info("termination: shutting CEF down")
      AppLog.app.info("termination: CEF is down; requesting final termination")
      runtime.record("termination:finished")
      onFinished()
    }
  }
}
