//
//  BeforeUnloadSelfTest.swift
//  NativeBrowser
//
//  Native-NSAlert integration driver for the deterministic beforeunload
//  contract. The shell supplies an explicit test response so the driver can
//  verify both branches without guessing from callback timing.
//

import AppKit
import Foundation

@MainActor
enum BeforeUnloadSelfTest {
  private static let prefix = "--beforeunload-self-test="
  private enum Choice: Equatable {
    case cancel
    case accept
  }

  static func installIfRequested(runtime: ApplicationRuntime) -> Bool {
    guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else {
      return false
    }
    let value = String(argument.dropFirst(prefix.count))
    let choice: Choice
    switch value {
    case "cancel": choice = .cancel
    case "accept": choice = .accept
    default:
      print("beforeunload-self-test: FAIL known-choice")
      exit(2)
    }
    run(runtime: runtime, choice: choice)
    return true
  }

  private static func run(runtime: ApplicationRuntime, choice: Choice) -> Never {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "NativeBrowser beforeunload self-test"
    let host = BrowserSurfaceHostView(frame: window.contentLayoutRect)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    window.makeKeyAndOrderFront(nil)

    let workspace = runtime.workspaceStore
    workspace.attachSurfaceHost(host)
    runtime.startMessagePump()

    guard let session = workspace.selectedSession,
      let tabID = workspace.selectedTabID
    else {
      print("beforeunload-self-test: FAIL setup")
      runtime.shutdownCEF()
      exit(2)
    }

    var failures = 0
    func check(_ condition: Bool, _ name: String) {
      if condition {
        print("beforeunload-self-test: pass \(name)")
      } else {
        print("beforeunload-self-test: FAIL \(name)")
        failures += 1
      }
    }

    let loaded = waitUntil(timeout: 45) {
      session.hasFinishedFirstLoad && session.lastErrorCode == nil
    }
    check(loaded, "fixture-loaded")

    if loaded {
      // Chromium suppresses beforeunload prompts until the page has sticky user
      // activation. This is test setup only; the manual flow supplies it by a
      // real page click before the user closes the tab.
      session.sendTestUserActivation()
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    workspace.closeSelectedTab()
    switch choice {
    case .cancel:
      let cancelled = waitUntil(timeout: 20) {
        workspace.tab(withID: tabID) != nil
          && workspace.session(for: tabID) === session
          && !session.isClosed
          && !workspace.sessionManager.isClosePending(tabID: tabID)
      }
      check(cancelled, "cancel-keeps-tab-and-session-live")
      check(workspace.recentlyClosed.isEmpty, "cancel-does-not-add-recently-closed")
    case .accept:
      let removed = waitUntil(timeout: 20) {
        workspace.tab(withID: tabID) == nil
      }
      check(removed, "accept-removes-tab")
      let closed = waitUntil(timeout: 30) { session.isClosed }
      check(closed, "accept-reaches-onbeforeclose")
      let closeEvents = runtime.lifecycleTrace.filter { $0 == "browser:closed" }.count
      check(closeEvents == 1, "accept-onbeforeclose-exactly-once")
    }

    runtime.requestBrowserClosure()
    let allClosed = waitUntil(timeout: 30) { !runtime.hasLiveBrowsers }
    check(allClosed, "termination-closes-remaining-runtimes")
    let shutdown = runtime.shutdownCEF()
    check(shutdown || runtime.hasShutDownCEF, "cef-shutdown-once")
    check(runtime.cefShutdownCount == 1, "cef-shutdown-count-is-one")

    window.close()
    print("beforeunload-self-test: choice=\(choice == .cancel ? "cancel" : "accept") failures=\(failures)")
    runtime.emitLifecycleTrace()
    exit(failures == 0 ? 0 : 2)
  }

  private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
  }
}
