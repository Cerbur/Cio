//
//  AppDelegate.swift
//  NativeBrowser
//

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

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private var terminator: ApplicationRuntime.Terminator?
  private var terminationReady = false

  /// Cancel this request so the native key event and any enclosing CEF call
  /// return completely. terminateLater enters a nested modal loop INSIDE
  /// terminate(_:); a timer firing there is not proof that CEF is off-stack.
  /// Once cleanup finishes, issue a new termination request and allow it.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let runtime = ApplicationRuntime.shared
    if terminationReady || runtime.hasShutDownCEF {
      runtime.record("appkit:terminate-ready")
      return .terminateNow
    }

    // Repeated Cmd+Q requests must neither restart cleanup nor reset its clock.
    guard terminator == nil else { return .terminateCancel }
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
    // Do not undo the Terminator's timeout protection by calling CefShutdown
    // with live browsers from this second entry point.
    if !runtime.hasLiveBrowsers {
      runtime.shutdownCEF()
    }
    // The late dump is what proves the Command-W conflict stayed resolved for
    // the whole run, not only at launch.
    if CommandLine.arguments.contains("--dump-main-menu") {
      MainMenuDump.printMainMenu("will-terminate")
    }
    runtime.emitLifecycleTrace()
  }
}
