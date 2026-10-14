import AppKit
import Foundation

/// Exercises the real Chromium frontend and Cio's native hosts with an isolated
/// profile (Scripts/verify_devtools.sh), including closing during startup.
@MainActor
enum DevToolsSelfTest {
  static func run(runtime: ApplicationRuntime) -> Int32 {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = makeBrowserSurfaceHost(frame: window.contentLayoutRect)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    runtime.workspaceStore.attachSurfaceHost(host)
    runtime.startMessagePump()

    var failures = 0
    func check(_ name: String, _ condition: Bool) {
      print("devtools-self-test: \(condition ? "pass" : "FAIL") \(name)")
      if !condition { failures += 1 }
    }
    func container(in view: NSView) -> ChromiumContainerView? {
      if let view = view as? ChromiumContainerView { return view }
      return view.subviews.lazy.compactMap { container(in: $0) }.first
    }
    guard let session = runtime.workspaceStore.selectedSession,
          let container = container(in: host) else { return 2 }
    check("page-loaded", waitUntil { session.hasFinishedFirstLoad })

    session.toggleDevTools()
    check("frontend-mounted", waitUntil {
      !container.devToolsHostView.subviews.isEmpty
        && container.devToolsHostView.subviews.allSatisfy { $0.frame.size == container.devToolsHostView.bounds.size }
    })
    check("bottom-dock-keeps-page-at-top", waitUntil(stableFor: 0.5) {
      container.pageContentView.frame.minY == 0
        && container.pageContentView.frame.height > 0
        && container.pageContentView.frame.height < container.bounds.height
    })
    session.toggleDevTools()
    check("close-restores-page", waitUntil {
      !session.isDevToolsOpen && !container.isDevToolsVisible
        && container.devToolsHostView.subviews.isEmpty && container.pageContentView.frame == container.bounds
    })

    if !session.isDevToolsOpen {
      session.toggleDevTools()
      session.toggleDevTools()
      check("close-during-startup", waitUntil { !session.isDevToolsOpen && !container.isDevToolsVisible })
      session.toggleDevTools()
      check("reopen-mounted", waitUntil { !container.devToolsHostView.subviews.isEmpty })
      session.toggleDevTools()
      check("reopen-closed", waitUntil { !session.isDevToolsOpen && container.pageContentView.frame == container.bounds })
    }

    runtime.requestBrowserClosure()
    check("sessions-closed", waitUntil { !runtime.hasLiveBrowsers })
    _ = runtime.shutdownBrowserEngine()
    window.close()
    print("devtools-self-test: failures=\(failures)")
    return failures == 0 ? 0 : 2
  }

  private static func waitUntil(stableFor: TimeInterval = 0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(8)
    var satisfiedAt: Date?
    while Date() < deadline {
      if condition() {
        if satisfiedAt == nil { satisfiedAt = Date() }
        if Date().timeIntervalSince(satisfiedAt!) >= stableFor { return true }
      } else {
        satisfiedAt = nil
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return false
  }
}
