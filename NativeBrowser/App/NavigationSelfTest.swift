//
//  NavigationSelfTest.swift
//  NativeBrowser
//
//  Milestone 2 integration self-test (Scripts/verify_milestone2.sh).
//
//  This drives the real navigation stack - BrowserSession, BrowserBridge,
//  CEFClientHandler, Chromium - without a human at the keyboard. It checks the
//  parts of Milestone 2 that can be observed programmatically:
//
//    * the address-field parser, exercised through the session's submit path
//      (including a Chinese query),
//    * main-frame URL and page title synchronisation,
//    * canGoBack / canGoForward reported by CEF after link navigation and after
//      Back / Forward,
//    * Reload and Stop reaching CEF,
//    * the Chromium browser being created exactly once across navigations.
//
//  It does NOT check anything that needs a human: window chrome, button
//  enablement as drawn on screen, ⌘L from the menu, focus behaviour, IME
//  candidate windows or resizing feel. Those stay in the manual checklist.
//

import AppKit
import Foundation

@MainActor
enum NavigationSelfTest {
  private static let primaryURL = URL(string: "https://www.google.com/")!
  private static let secondURL = URL(string: "https://example.com/")!
  private static let thirdURL = URL(string: "https://example.org/")!

  /// Runs the self-test. Returns the process exit code.
  static func run(runtime: ApplicationRuntime) -> Int32 {
    let workspace = runtime.workspaceStore
    let manager = workspace.sessionManager
    var failures = 0
    var checks = 0

    /// Reports one check. The detail is captured into a log file by
    /// Scripts/verify_milestone2.sh, so every URL it echoes is passed through
    /// URLLogSanitizer by the caller: the self-test drives the real browser and
    /// a navigation can end up anywhere.
    func report(_ name: String, _ passed: Bool, _ detail: String) {
      checks += 1
      if !passed { failures += 1 }
      print("navigation-self-test: \(passed ? "pass" : "FAIL") \(name) - \(detail)")
      runtime.record("selftest:m2:\(name)=\(passed)")
    }

    // The real window and the real surface host: CEF attaches its browser view
    // to a container inside this NSView exactly as it does in the application.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "NativeBrowser navigation self-test"
    let host = BrowserSurfaceHostView(frame: window.contentLayoutRect)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    // The window has to be a real, key window: Chromium destroys the browser
    // when its host view deallocates, and a view in a window that was never
    // ordered in front (or made key) is not torn down the same way.
    window.makeKeyAndOrderFront(nil)
    workspace.attachSurfaceHost(host)
    runtime.startMessagePump()

    // The tab the manager created at launch, reached through the Milestone 3
    // ownership path rather than through a single-browser property.
    guard let session = workspace.selectedSession else {
      print("navigation-self-test: FAIL no-tab - the workspace created no tab")
      return 2
    }

    // 1. Initial page.
    let initialLoaded = wait(until: { session.hasFinishedFirstLoad }, timeout: 45)
    report(
      "initial-load", initialLoaded && session.lastErrorCode == nil,
      "url=\(URLLogSanitizer.sanitized(session.url)) title=\(session.title)")

    let initialURL = session.url?.absoluteString ?? ""
    report(
      "initial-url-is-main-frame", initialURL.contains("google.com"),
      "url=\(URLLogSanitizer.sanitized(initialURL))")

    let title = session.title
    report("initial-title", !title.isEmpty, "title=\(title)")

    let createdAfterFirstLoad = session.browserCreationCount
    report(
      "browser-created-once", createdAfterFirstLoad == 1,
      "creations=\(createdAfterFirstLoad)")

    // 2. Address-field submit path: text with spaces is a Google search.
    let query = "浏览器 Chromium CEF"
    session.addressField.userChangedText(query)
    session.submitAddressField()
    let expectedSearchURL = GoogleSearchEngine().searchURL(for: query).absoluteString
    let searched = wait(
      until: { session.url?.absoluteString == expectedSearchURL }, timeout: 45)
    report(
      "chinese-query-search", searched,
      "expected=\(URLLogSanitizer.sanitized(expectedSearchURL)) actual=\(URLLogSanitizer.sanitized(session.url))")

    // 3. Direct URL navigation updates the address field, not just the session.
    session.load(secondURL)
    let secondLoaded = wait(
      until: {
        session.url?.absoluteString == secondURL.absoluteString && !session.isLoading
      }, timeout: 45)
    report(
      "url-navigation", secondLoaded,
      "url=\(URLLogSanitizer.sanitized(session.url)) title=\(session.title)")
    report(
      "address-field-tracks-url",
      session.addressField.editText == secondURL.absoluteString,
      "field=\(URLLogSanitizer.sanitized(session.addressField.editText))")
    report(
      "back-available-after-navigation", session.canGoBack,
      "canGoBack=\(session.canGoBack)")

    // 4. A further navigation, so that Back and Forward both have somewhere to
    //    go.
    session.load(thirdURL)
    let thirdLoaded = wait(
      until: {
        session.url?.absoluteString == thirdURL.absoluteString && !session.isLoading
      }, timeout: 45)
    report(
      "second-navigation", thirdLoaded, "url=\(URLLogSanitizer.sanitized(session.url))")

    // 5. Back.
    session.goBack()
    let wentBack = wait(
      until: { session.url?.absoluteString == secondURL.absoluteString && !session.isLoading },
      timeout: 30)
    report(
      "back-navigates", wentBack, "url=\(URLLogSanitizer.sanitized(session.url))")
    report(
      "forward-available-after-back", session.canGoForward,
      "canGoForward=\(session.canGoForward)")

    // 6. Forward.
    session.goForward()
    let wentForward = wait(
      until: { session.url?.absoluteString == thirdURL.absoluteString && !session.isLoading },
      timeout: 30)
    report(
      "forward-navigates", wentForward, "url=\(URLLogSanitizer.sanitized(session.url))")

    // 7. Stop. A fresh navigation is started and cancelled while Chromium is
    //    still loading.
    session.load(primaryURL)
    _ = wait(until: { session.isLoading }, timeout: 5)
    session.stop()
    let stopped = wait(until: { !session.isLoading }, timeout: 15)
    report("stop-load", stopped, "isLoading=\(session.isLoading)")

    // 8. Reload of a loaded page completes without a navigation error.
    session.load(secondURL)
    _ = wait(
      until: {
        session.url?.absoluteString == secondURL.absoluteString && !session.isLoading
      }, timeout: 45)
    let errorBeforeReload = session.lastErrorCode
    let loadsBeforeReload = session.loadStartCount
    session.reload()
    // A reload keeps the same URL, so the proof that it reached Chromium is the
    // loading state going busy again and then settling.
    let reloadStarted = wait(
      until: { session.loadStartCount > loadsBeforeReload }, timeout: 15)
    let reloadFinished = wait(
      until: {
        session.url?.absoluteString == secondURL.absoluteString && !session.isLoading
          && session.lastErrorCode == errorBeforeReload
      }, timeout: 30)
    report(
      "reload-started", reloadStarted,
      "loads=\(session.loadStartCount - loadsBeforeReload)")
    report(
      "reload", reloadStarted && reloadFinished,
      "url=\(URLLogSanitizer.sanitized(session.url)) error=\(session.lastErrorCode.map(String.init) ?? "none")")

    // 9. Navigation must never have built a second Chromium browser.
    report(
      "browser-not-recreated",
      session.browserCreationCount == createdAfterFirstLoad,
      "creations=\(session.browserCreationCount)")

    // 10. Close the browser and shut CEF down the way the application does.
    //
    //     Chromium only destroys a browser promptly in this harness while its
    //     renderer is idle; after many navigations it defers destruction past
    //     any reasonable deadline. The freshly created browser below is
    //     therefore used to check the close path, and the application's own
    //     quit runs (section 6 of Scripts/verify_milestone2.sh) check it for a
    //     browser that has navigated and while a page is still loading.
    //
    //     The fresh browser is a real second tab created through the manager,
    //     so it exercises the same ownership path the application uses. It is
    //     created *without* taking the selection: a browser whose container
    //     goes visible -> hidden in the same run-loop turn as its close does not
    //     deallocate in this harness (verified: the CEF host view stays alive
    //     and OnBeforeClose is deferred until the window is destroyed), while
    //     the same close from a steady-state background tab completes
    //     immediately. The application itself is not affected - section 3 of
    //     Scripts/verify_milestone3.sh closes a *selected* tab in the running
    //     application and asserts that it reaches OnBeforeClose.
    let freshURL = URL(string: "about:blank")!
    let freshTabID = workspace.createTab(url: freshURL, select: false)
    let freshSession = freshTabID.flatMap { manager.session(for: $0) }

    let freshLoaded = freshSession.map { session in
      wait(until: { session.hasFinishedFirstLoad }, timeout: 30)
    } ?? false
    report(
      "fresh-browser-loads", freshLoaded,
      "url=\(URLLogSanitizer.sanitized(freshSession?.url))")

    // Pumped exactly the way the runtime pumps during application termination,
    // because that is the path this check exists to corroborate.
    let closeStarted = Date()
    if let freshTabID {
      workspace.closeTab(id: freshTabID)
    }
    let closeDeadline = closeStarted.addingTimeInterval(20)
    while !(freshSession?.isClosed ?? true), Date() < closeDeadline {
      runtime.pumpMessageLoop()
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let closeSeconds = Date().timeIntervalSince(closeStarted)
    report(
      "browser-closed", freshSession?.isClosed ?? false,
      "isClosed=\(freshSession?.isClosed ?? false) seconds=\(String(format: "%.2f", closeSeconds))")
    // The remaining browser is the one that navigated through this whole test.
    // Chromium defers destroying a browser in this harness once its renderer has
    // done real work (the Milestone 2 notes recorded the same behaviour), and
    // the application's own quit runs - section 6 below and section 4 of
    // Scripts/verify_milestone3.sh - are what check that a navigated browser is
    // destroyed before CefShutdown. Here the window is closed and CEF is shut
    // down, exactly as Milestone 2 did.
    window.close()
    runtime.shutdownCEF()
    report("cef-clean-shutdown", !CEFProcessHost.isInitialized, "cefInitialized=false")

    print(
      "navigation-self-test: checks=\(checks) failures=\(failures) browser-creations=\(session.browserCreationCount) title=\(session.title)"
    )
    runtime.emitLifecycleTrace()
    return failures == 0 ? 0 : 2
  }

  /// Pumps the CEF message loop until `condition` holds or the timeout expires.
  ///
  /// `RunLoop.main.run(until:)` is what delivers CEF callbacks here: the
  /// application owns the message loop and pumps it from the main run loop.
  @discardableResult
  private static func wait(
    until condition: () -> Bool,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
  }
}
