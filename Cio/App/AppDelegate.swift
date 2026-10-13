//
//  AppDelegate.swift
//  Cio
//

import CioEngine
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    AppLog.app.info("application did finish launching")
    ApplicationRuntime.shared.record("appkit:did-finish-launching")
    // Command-W must close the selected tab, not the window (Milestone 3
    // section 21). The scene installs AppKit's standard window Close item, which
    // claims the same key equivalent; it is removed here rather than shadowed,
    // because two items with one key equivalent resolve by menu order.
    MainMenuDump.claimCloseTabShortcut()
    if CommandLine.arguments.contains("--dump-main-menu") {
      MainMenuDump.printMainMenu("launch")
    }
    ApplicationRuntime.shared.startMessagePump()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    ApplicationRuntime.shared.openExternalURLs(urls)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private var terminator: ApplicationRuntime.Terminator?
  private var terminationReady = false
  private var downloadConfirmation: NSAlert?
  private var confirmedDownloadCancellation = false

  /// Cancel this request so the native key event and any enclosing Chromium call
  /// return completely. terminateLater enters a nested modal loop INSIDE
  /// terminate(_:); a timer firing there is not proof that Chromium is off-stack.
  /// Once cleanup finishes, issue a new termination request and allow it.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let runtime = ApplicationRuntime.shared
    if terminationReady || runtime.hasShutDownBrowserEngine {
      runtime.record("appkit:terminate-ready")
      return .terminateNow
    }

    // Keep in-progress files alive unless the user explicitly quits and cancels.
    // Repeated quit requests must not stack sheets or start engine teardown.
    guard terminator == nil else { return .terminateCancel }
    if runtime.downloadManager.activeDownloadCount > 0 && !confirmedDownloadCancellation {
      guard downloadConfirmation == nil, let window = NSApp.mainWindow else { return .terminateCancel }
      let alert = NSAlert()
      alert.messageText = "下载尚未完成"
      alert.informativeText = "退出 Cio 会取消正在进行的下载。"
      alert.addButton(withTitle: "继续下载")
      alert.addButton(withTitle: "退出并取消下载")
      downloadConfirmation = alert
      alert.beginSheetModal(for: window) { [weak self] response in
        guard let self else { return }
        self.downloadConfirmation = nil
        if response == .alertSecondButtonReturn {
          self.confirmedDownloadCancellation = true
          NSApp.terminate(nil)
        }
      }
      return .terminateCancel
    }
    // Repeated Cmd+Q requests must neither restart cleanup nor reset its clock.
    guard runtime.workspaceStore.flushSessionPersistence() else { return .terminateCancel }
    runtime.markShutdownPhase("T0")
    runtime.record("appkit:should-terminate(entered)")
    terminator = ApplicationRuntime.Terminator(runtime: runtime) { [weak self] in
      guard let self else { return }
      self.terminationReady = true
      runtime.markShutdownPhase("T7")
      runtime.record("appkit:terminate-ready-requested")
      NSApp.terminate(nil)
    }
    terminator?.start()
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    let runtime = ApplicationRuntime.shared
    runtime.record("appkit:will-terminate")
    // The Terminator calls native engine shutdown only after every typed OnBeforeClose
    // callback has released its session. Never bypass that ordering here.
    if !runtime.hasLiveBrowsers {
      runtime.shutdownBrowserEngine()
    }
    SessionRestoreSelfTest.noteTerminationCompletion()
    // The late dump is what proves the Command-W conflict stayed resolved for
    // the whole run, not only at launch.
    if CommandLine.arguments.contains("--dump-main-menu") {
      MainMenuDump.printMainMenu("will-terminate")
    }
    runtime.emitLifecycleTrace()
  }
}
