//
//  AppDelegate.swift
//  NativeBrowser
//
//  AppKit side of the application lifecycle. The CEF boundary is AppKit/RunLoop
//  aware, so the delegate is the natural owner of the startup and shutdown
//  hand-offs.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    AppLog.app.info("application did finish launching")
    ApplicationRuntime.shared.record("appkit:did-finish-launching")
    // The app owns the run loop, so CEF's message loop is pumped explicitly.
    ApplicationRuntime.shared.startMessagePump()


  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    AppLog.app.info("application will terminate")
    let runtime = ApplicationRuntime.shared
    runtime.record("appkit:will-terminate")
    runtime.prepareForTermination()
    runtime.shutdownCEF()
    runtime.emitLifecycleTrace()
  }
}
