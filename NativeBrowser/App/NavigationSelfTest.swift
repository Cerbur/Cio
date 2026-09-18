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
    let session = runtime.browserSession
    var failures = 0
    var checks = 0

    func report(_ name: String, _ passed: Bool, _ detail: String) {
      checks += 1
      if !passed { failures += 1 }
      print("navigation-self-test: \(passed ? "pass" : "FAIL") \(name) - \(detail)")
      runtime.record("selftest:m2:\(name)=\(passed)")
    }

    // The real window and the real container: CEF attaches its browser view to
    // this NSView exactly as it does in the application.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "NativeBrowser navigation self-test"
    let container = ChromiumContainerView(frame: window.contentLayoutRect)
    container.autoresizingMask = [.width, .height]
    window.contentView = container
    // The window has to be a real, key window: Chromium destroys the browser
    // when its host view deallocates, and a view in a window that was never
    // ordered in front (or made key) is not torn down the same way.
    window.makeKeyAndOrderFront(nil)
    session.attach(to: container)
    runtime.startMessagePump()

    // 1. Initial page.
    let initialLoaded = wait(until: { session.hasFinishedFirstLoad }, timeout: 45)
    report(
      "initial-load", initialLoaded && session.lastErrorCode == nil,
      "url=\(session.url?.absoluteString ?? "nil") title=\(session.title)")

    let initialURL = session.url?.absoluteString ?? ""
    report(
      "initial-url-is-main-frame", initialURL.contains("google.com"),
      "url=\(initialURL)")

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
      "expected=\(expectedSearchURL) actual=\(session.url?.absoluteString ?? "nil")")

    // 3. Direct URL navigation updates the address field, not just the session.
    session.load(secondURL)
    let secondLoaded = wait(
      until: {
        session.url?.absoluteString == secondURL.absoluteString && !session.isLoading
      }, timeout: 45)
    report(
      "url-navigation", secondLoaded,
      "url=\(session.url?.absoluteString ?? "nil") title=\(session.title)")
    report(
      "address-field-tracks-url",
      session.addressField.editText == secondURL.absoluteString,
      "field=\(session.addressField.editText)")
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
      "second-navigation", thirdLoaded, "url=\(session.url?.absoluteString ?? "nil")")

    // 5. Back.
    session.goBack()
    let wentBack = wait(
      until: { session.url?.absoluteString == secondURL.absoluteString && !session.isLoading },
      timeout: 30)
    report(
      "back-navigates", wentBack, "url=\(session.url?.absoluteString ?? "nil")")
    report(
      "forward-available-after-back", session.canGoForward,
      "canGoForward=\(session.canGoForward)")

    // 6. Forward.
    session.goForward()
    let wentForward = wait(
      until: { session.url?.absoluteString == thirdURL.absoluteString && !session.isLoading },
      timeout: 30)
    report(
      "forward-navigates", wentForward, "url=\(session.url?.absoluteString ?? "nil")")

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
      "url=\(session.url?.absoluteString ?? "nil") error=\(session.lastErrorCode.map(String.init) ?? "none")")

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
    let freshContainer = ChromiumContainerView(frame: window.contentLayoutRect)
    freshContainer.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(freshContainer)
    NSLayoutConstraint.activate([
      freshContainer.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
      freshContainer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
      freshContainer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
      freshContainer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
    ])
    let freshSession = BrowserSession(initialURL: URL(string: "about:blank")!)
    runtime.registerLiveSession(freshSession)
    freshSession.attach(to: freshContainer)

    let freshLoaded = wait(until: { freshSession.hasFinishedFirstLoad }, timeout: 30)
    report(
      "fresh-browser-loads", freshLoaded,
      "url=\(freshSession.url?.absoluteString ?? "nil")")

    // Pumped exactly the way ApplicationRuntime.closeBrowserSessions() pumps
    // during application termination, because that is the path this check
    // exists to corroborate.
    let closeStarted = Date()
    freshSession.close()
    let closeDeadline = closeStarted.addingTimeInterval(20)
    while !freshSession.isClosed, Date() < closeDeadline {
      runtime.pumpMessageLoop()
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let closeSeconds = Date().timeIntervalSince(closeStarted)
    report(
      "browser-closed", freshSession.isClosed,
      "isClosed=\(freshSession.isClosed) seconds=\(String(format: "%.2f", closeSeconds))")
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
