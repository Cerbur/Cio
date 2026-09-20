//
//  TabsSelfTest.swift
//  NativeBrowser
//
//  Milestone 3 multi-tab integration self-test (Scripts/verify_milestone3.sh).
//
//  Unlike the Milestone 1 and Milestone 2 self-tests, this one does NOT build a
//  private window and drive a hand-rolled run loop. It runs inside the real
//  application: the real SwiftUI `Window`, the real BrowserSurfaceView host,
//  the real BrowserSessionManager, and the real NSApplication run loop. That
//  matters, because it is the only configuration in which Chromium actually
//  completes a browser teardown for a page that has finished loading - a
//  hand-rolled `RunLoop.main.run(until:)` harness delivers DoClose but defers
//  OnBeforeClose for minutes (the Milestone 2 self-test documents the same
//  behaviour and works around it).
//
//  The test therefore proves, with the production ownership path:
//
//    A. several sessions create several Chromium browsers
//    B. every session owns a distinct Chromium browser identity
//    C. every session holds its own URL
//    D. selecting and switching tabs never increments browserCreationCount
//    E. closing one browser reaches OnBeforeClose
//    F. closing one browser leaves the others alive and usable
//    G. a remaining browser can still navigate
//    H. every browser closes before CefShutdown
//    I. CefShutdown runs exactly once
//    J. the shutdown wait needed no timeout fallback
//
//  plus the section 33 stress shape (several real browsers created and
//  destroyed with no duplicated identity) and the section 20 last-tab rule.
//
//  The Milestone 3 focus fix is checked here too, with real AppKit state
//  (BrowserSession.holdsAppKitKeyboardFocus) rather than a proxy:
//
//    K. the selected page can own AppKit's first responder at all
//    L. a selected-page tab switch moves it from the old session to the new one
//    M. a tab created with select=false gets a real browser without touching
//       the selection or the keyboard
//    N. a tab whose browser arrives *after* it was hidden again does not steal
//       the keyboard (the asynchronous OnAfterCreated race)
//    O. closing a background tab leaves the active tab's keyboard ownership
//       alone
//    P. closing the selected tab hands the keyboard to the tab that replaces it
//    Q. a tab change while the native address field owns the keyboard leaves the
//       field editor first responder (the page follows the keyboard; it never
//       takes it)
//
//  It still does NOT check anything that needs a human: sidebar appearance, real
//  key events for Cmd-T/Cmd-W, a real key event reaching the page, Chinese IME,
//  or window resizing feel. Those stay in the manual checklist.

import AppKit
import Foundation

@MainActor
final class TabsSelfTest {
  /// The running instance. The application keeps it for the whole run.
  private static var active: TabsSelfTest?

  /// Installs the self-test when `--tabs-self-test` was passed. Returns whether
  /// it was installed; the application then runs normally.
  @discardableResult
  static func installIfRequested(runtime: ApplicationRuntime) -> Bool {
    guard CommandLine.arguments.contains("--tabs-self-test") else { return false }
    let test = TabsSelfTest(runtime: runtime)
    active = test
    test.start()
    return true
  }

  // MARK: - Configuration

  /// Four extra tabs, so five browsers are live at once in the phase that proves
  /// switching and single-tab close. Distinct paths keep every URL distinct.
  private static let extraTabURLs: [URL] = [
    URL(string: "https://example.com/tab-2")!,
    URL(string: "https://example.com/tab-3")!,
    URL(string: "https://example.org/tab-4")!,
    URL(string: "https://example.org/tab-5")!,
  ]

  /// A smaller automated stress count than the manual 20-tab check, so the run
  /// stays quick: five more real browsers are created and destroyed.
  private static let stressTabURLs: [URL] = [
    URL(string: "https://example.com/stress-1")!,
    URL(string: "https://example.org/stress-2")!,
    URL(string: "https://example.com/stress-3")!,
    URL(string: "https://example.org/stress-4")!,
    URL(string: "https://example.com/stress-5")!,
  ]

  private static let navigationAfterClose = URL(string: "https://example.org/after-close")!
  private static let afterTermination = URL(string: "https://example.com/after-termination")!

  /// One phase of the run.
  ///
  /// `advance` is called once per tick until it returns true or `timeout`
  /// expires, which is how the phases wait for real Chromium callbacks without
  /// blocking the run loop (nothing here sleeps or polls a private queue).
  private struct Step {
    let name: String
    let timeout: TimeInterval
    var begin: () -> Void = {}
    let advance: () -> Bool
    let finish: (_ completed: Bool) -> Void
  }

  // MARK: - State

  private let runtime: ApplicationRuntime
  private let manager: BrowserSessionManager

  private var steps: [Step] = []
  private var stepIndex = 0
  private var didBeginStep = false
  private var stepDeadline = Date.distantPast
  private var timer: Timer?

  private var checks = 0
  private var failures = 0
  private var observedBrowserIdentifiers: Set<Int> = []

  // Per-phase state
  private var initialTabID: UUID?
  private var victimTabID: UUID?
  private var victimSession: BrowserSession?
  private var survivors: [BrowserSession] = []
  private var stressSessions: [BrowserSession] = []
  private var lastTabID: UUID?
  private var switchCount = 0
  private var creationsBeforeSwitch: [String] = []
  private var identifiersBeforeSwitch: [Int] = []
  private var urlChangesBeforeSwitch: [Int] = []
  /// The tab the asynchronous-creation race left behind, so the next phase can
  /// close it as a background tab.
  private var racedTabID: UUID?
  private var navigateURLChangesBefore = 0
  private var terminationStarted = Date()
  private var liveAtTermination = 0

  private init(runtime: ApplicationRuntime) {
    self.runtime = runtime
    self.manager = runtime.sessionManager
  }

  private var initialSession: BrowserSession? {
    initialTabID.flatMap { manager.session(for: $0) }
  }

  // MARK: - Driver

  private func start() {
    steps = buildSteps()
    // A repeating timer on the main run loop: the same way the application
    // pumps CEF, so every callback this test waits for arrives exactly as it
    // would in normal use.
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated {
        TabsSelfTest.active?.tick()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    guard stepIndex < steps.count else { return }
    let step = steps[stepIndex]

    if !didBeginStep {
      didBeginStep = true
      stepDeadline = Date().addingTimeInterval(step.timeout)
      step.begin()
      return
    }

    let completed = step.advance()
    guard completed || Date() >= stepDeadline else { return }
    if !completed {
      AppLog.session.error("tabs-self-test: step \(step.name, privacy: .public) timed out")
    }
    step.finish(completed)
    stepIndex += 1
    didBeginStep = false
  }

  // MARK: - Steps

  private func buildSteps() -> [Step] {
    [
      waitForInitialTab(),
      createExtraTabs(),
      switchTabs(),
      pageHoldsKeyboard(),
      switchMovesKeyboard(),
      addressFieldHoldsKeyboard(),
      tabChangeKeepsAddressField(),
      backgroundTabDoesNotStealFocus(),
      lateOnAfterCreatedDoesNotStealFocus(),
      backgroundCloseKeepsKeyboard(),
      closeSelectedTransfersKeyboard(),
      closeBackgroundTab(),
      navigateSurvivor(),
      createStressTabs(),
      closeStressTabs(),
      drainToLastTab(),
      closeLastTab(),
      closeEverything(),
      shutCefDown(),
    ]
  }

  private func waitForInitialTab() -> Step {
    Step(
      name: "initial-tab",
      timeout: 180,
      begin: {
        // The manager created exactly one tab before the window appeared.
        self.initialTabID = self.manager.tabs.first?.id
      },
      advance: {
        guard let session = self.initialSession else { return false }
        return session.hasFinishedFirstLoad && self.manager.tabs.count == 1
      },
      finish: { completed in
        self.report(
          "initial-tab-loads", completed && self.manager.tabs.count == 1,
          "tabs=\(self.manager.tabs.count) url=\(URLLogSanitizer.sanitized(self.initialSession?.url))")
      })
  }

  private func createExtraTabs() -> Step {
    Step(
      name: "create-tabs",
      timeout: 240,
      begin: {
        for url in Self.extraTabURLs {
          self.manager.createTab(url: url)
        }
      },
      advance: {
        let expected = 1 + Self.extraTabURLs.count
        let sessions = self.manager.liveSessions
        guard self.manager.tabs.count == expected, sessions.count == expected else {
          return false
        }
        let expectedURLs = Set(Self.extraTabURLs.map(\.absoluteString))
        let observed = Set(sessions.compactMap { $0.url?.absoluteString })
        return sessions.allSatisfy { $0.browserCreationCount == 1 && $0.hasBrowser }
          && expectedURLs.isSubset(of: observed)
          && observed.count == expected
      },
      finish: { completed in
        let sessions = self.manager.liveSessions
        let identifiers = sessions.compactMap { $0.browserIdentifier }
        self.observedBrowserIdentifiers.formUnion(identifiers)
        self.report(
          "multiple-browsers-created",
          completed && sessions.count == 1 + Self.extraTabURLs.count,
          "sessions=\(sessions.count) creations=\(sessions.map { String($0.browserCreationCount) }.joined(separator: ","))"
        )
        self.report(
          "distinct-browser-identity",
          identifiers.count == sessions.count && Set(identifiers).count == identifiers.count,
          "browsers=\(identifiers.count) distinct=\(Set(identifiers).count)")
        let observed = Set(sessions.compactMap { $0.url?.absoluteString })
        self.report(
          "distinct-urls",
          completed && observed.count == sessions.count,
          "expected=\(Self.extraTabURLs.count) distinct-observed=\(observed.count) sessions=\(sessions.count)"
        )
      })
  }

  private func switchTabs() -> Step {
    var order: [UUID] = []
    return Step(
      name: "switch-tabs",
      timeout: 60,
      begin: {
        order = self.manager.tabs.map(\.id)
        self.creationsBeforeSwitch = self.manager.liveSessions.map {
          $0.tabID.uuidString + ":\($0.browserCreationCount)"
        }
        self.identifiersBeforeSwitch = self.manager.liveSessions.compactMap { $0.browserIdentifier }
          .sorted()
        self.urlChangesBeforeSwitch = self.manager.liveSessions.map(\.mainFrameURLChangeCount)
        self.switchCount = 0
      },
      advance: {
        guard self.switchCount < order.count * 3 else { return true }
        self.switchCount += 1
        // Walk the list; selectTab is a no-op when the walk lands on the current
        // tab, and the rotation guarantees many real switches either way.
        self.manager.selectTab(id: order[self.switchCount % order.count])
        return false
      },
      finish: { completed in
        let creationsAfter = self.manager.liveSessions.map {
          $0.tabID.uuidString + ":\($0.browserCreationCount)"
        }
        let identifiersAfter = self.manager.liveSessions.compactMap { $0.browserIdentifier }.sorted()
        let urlChangesAfter = self.manager.liveSessions.map(\.mainFrameURLChangeCount)
        self.report(
          "switch-does-not-recreate",
          completed && self.creationsBeforeSwitch == creationsAfter
            && self.identifiersBeforeSwitch == identifiersAfter
            && self.urlChangesBeforeSwitch == urlChangesAfter
            && creationsAfter.allSatisfy { $0.hasSuffix(":1") },
          "switches=\(self.switchCount) creations=\(self.manager.liveSessions.map { String($0.browserCreationCount) }.joined(separator: ","))"
        )
      })
  }

  // MARK: Focus steps (Milestone 3 focus fix)
  //
  // These steps observe AppKit's real first responder through
  // BrowserSession.holdsAppKitKeyboardFocus. They deliberately never synthesise a
  // key event, so they prove ownership of the keyboard, not what a keystroke
  // does with it: Cmd-key behaviour, typing into the page and IME stay manual.

  /// The precondition every other focus check needs: the selected page really can
  /// own AppKit's first responder, and the test can see it.
  private func pageHoldsKeyboard() -> Step {
    Step(
      name: "page-holds-keyboard",
      timeout: 30,
      begin: {
        self.manager.selectedSession?.focusPage()
      },
      advance: {
        self.manager.selectedSession?.holdsAppKitKeyboardFocus == true
      },
      finish: { completed in
        self.report(
          "selected-page-holds-keyboard", completed,
          self.focusDescription(of: self.manager.selectedSession))
      })
  }

  /// A selected-page tab switch moves the keyboard with the page: the outgoing
  /// session stops holding it and the newly selected one holds it.
  private func switchMovesKeyboard() -> Step {
    var outgoingID: UUID?
    var incomingID: UUID?
    return Step(
      name: "switch-moves-keyboard",
      timeout: 30,
      begin: {
        outgoingID = self.manager.selectedTabID
        incomingID = self.manager.tabs.map(\.id).first { $0 != outgoingID }
        if let incomingID {
          self.manager.selectTab(id: incomingID)
        }
      },
      advance: {
        guard let outgoingID, let incomingID,
          let outgoing = self.manager.session(for: outgoingID),
          let incoming = self.manager.session(for: incomingID)
        else { return true }
        return self.manager.selectedTabID == incomingID
          && !outgoing.holdsAppKitKeyboardFocus
          && incoming.holdsAppKitKeyboardFocus
      },
      finish: { completed in
        let outgoing = outgoingID.flatMap { self.manager.session(for: $0) }
        let incoming = incomingID.flatMap { self.manager.session(for: $0) }
        self.report(
          "switch-moves-keyboard",
          completed && self.manager.selectedTabID == incomingID
            && outgoing?.holdsAppKitKeyboardFocus == false
            && incoming?.holdsAppKitKeyboardFocus == true,
          "old=[\(self.focusDescription(of: outgoing))] new=[\(self.focusDescription(of: incoming))]")
      })
  }

  /// ⌘L in the real window: the native address field owns the keyboard. This
  /// runs the production notification path, not a private hook.
  private func addressFieldHoldsKeyboard() -> Step {
    Step(
      name: "address-field-holds-keyboard",
      timeout: 30,
      begin: {
        self.manager.selectedSession?.requestAddressFieldFocus()
      },
      advance: { self.addressFieldIsFirstResponder },
      finish: { completed in
        let pageFocused = self.manager.selectedSession?.holdsAppKitKeyboardFocus ?? false
        self.report(
          "address-field-holds-keyboard",
          completed && self.addressFieldIsFirstResponder && !pageFocused,
          "field-editor=\(self.addressFieldIsFirstResponder) page-focused=\(pageFocused)")
      })
  }

  /// Cmd-T while the address field owns the keyboard: the new tab is selected,
  /// its browser is created, and the field editor keeps the keyboard. A tab
  /// change must not pull focus into a newly created Chromium surface.
  private func tabChangeKeepsAddressField() -> Step {
    var createdTabID: UUID?
    var createdSession: BrowserSession?
    var ticksAfterBrowser = 0
    return Step(
      name: "tab-change-keeps-address-field",
      timeout: 90,
      begin: {
        createdTabID = self.manager.createTab(
          url: URL(string: "https://example.com/focus-address-field"))
        createdSession = createdTabID.flatMap { self.manager.session(for: $0) }
      },
      advance: {
        guard let createdSession else { return true }
        guard createdSession.hasBrowser, createdSession.browserCreationCount == 1 else {
          return false
        }
        // Two extra ticks: the browser exists, and any focus request it made
        // while being created has already been answered.
        ticksAfterBrowser += 1
        return ticksAfterBrowser >= 2
      },
      finish: { completed in
        let pageFocused = self.manager.liveSessions.contains { $0.holdsAppKitKeyboardFocus }
        self.report(
          "tab-change-keeps-address-focus",
          completed && self.manager.selectedTabID == createdTabID
            && self.addressFieldIsFirstResponder && !pageFocused,
          "created=\(self.shortID(createdTabID)) selected=\(self.shortID(self.manager.selectedTabID)) field-editor=\(self.addressFieldIsFirstResponder) any-page-focused=\(pageFocused) new=[\(self.focusDescription(of: createdSession))]")
      })
  }

  /// A tab created with `select: false` gets a real Chromium browser while the
  /// selection and the keyboard stay exactly where they were.
  private func backgroundTabDoesNotStealFocus() -> Step {
    var backgroundSession: BrowserSession?
    var selectedBefore: UUID?
    var heldBefore = false
    var ticks = 0
    var browserArrivedAtTick: Int?
    var focusAppearedAtTick: Int?
    return Step(
      name: "background-tab-creation",
      timeout: 90,
      begin: {
        selectedBefore = self.manager.selectedTabID
        // Put the keyboard in the selected page first, so a steal would be
        // visible as a change rather than as a no-op.
        self.manager.selectedSession?.focusPage()
        heldBefore = self.manager.selectedSession?.holdsAppKitKeyboardFocus ?? false
        let url = URL(string: "https://example.com/focus-background")!
        if let tabID = self.manager.createTab(url: url, select: false) {
          backgroundSession = self.manager.session(for: tabID)
        }
      },
      advance: {
        ticks += 1
        guard let backgroundSession else { return true }
        if backgroundSession.hasBrowser, backgroundSession.browserCreationCount == 1 {
          if browserArrivedAtTick == nil { browserArrivedAtTick = ticks }
        }
        // Diagnostic: when did the background surface first hold AppKit focus?
        if focusAppearedAtTick == nil, backgroundSession.holdsAppKitKeyboardFocus {
          focusAppearedAtTick = ticks
        }
        if let browserArrivedAtTick, ticks >= browserArrivedAtTick + 2 {
          return true
        }
        return false
      },
      finish: { completed in
        let background = backgroundSession
        let focusTick = focusAppearedAtTick.map(String.init) ?? "never"
        self.report(
          "background-creation-keeps-selection",
          completed && background != nil && self.manager.selectedTabID == selectedBefore,
          "selected-before=\(self.shortID(selectedBefore)) selected-after=\(self.shortID(self.manager.selectedTabID))")
        self.report(
          "background-browser-does-not-take-focus",
          completed && heldBefore && background != nil
            && background?.holdsAppKitKeyboardFocus == false
            && background?.isSurfaceVisible == false
            && self.manager.selectedSession?.holdsAppKitKeyboardFocus == heldBefore,
          "background=[\(self.focusDescription(of: background))] selected=[\(self.focusDescription(of: self.manager.selectedSession))] browser-tick=\(browserArrivedAtTick.map(String.init) ?? "never") focus-tick=\(focusTick) window-responder=\(self.responderClassName())")
      })
  }

  /// The asynchronous creation race: create a tab, move the selection straight
  /// back in the same turn (so Chromium cannot have delivered OnAfterCreated
  /// yet), and let the browser arrive afterwards. It must stay hidden and must
  /// not take AppKit's first responder.
  private func lateOnAfterCreatedDoesNotStealFocus() -> Step {
    var racedSession: BrowserSession?
    var keptTabID: UUID?
    var keptHeldKeyboard = false
    var browserArrived = false
    var browserWasPendingWhenDeselected = false
    var ticksAfterArrival = 0
    return Step(
      name: "late-browser-creation",
      timeout: 90,
      begin: {
        keptTabID = self.manager.selectedTabID
        self.manager.selectedSession?.focusPage()
        keptHeldKeyboard = self.manager.selectedSession?.holdsAppKitKeyboardFocus ?? false
        let url = URL(string: "https://example.org/focus-race")!
        if let tabID = self.manager.createTab(url: url) {
          racedSession = self.manager.session(for: tabID)
        }
        // No run-loop turn in between: this is the race the fix has to survive.
        if let keptTabID {
          self.manager.selectTab(id: keptTabID)
        }
        // Record that the race was real: Chromium had not delivered
        // OnAfterCreated while this tab was still the selected one, so the
        // browser really is created after the tab was hidden.
        browserWasPendingWhenDeselected =
          racedSession != nil && racedSession?.hasBrowser == false
          && (racedSession?.browserCreationCount ?? 0) == 0
        self.racedTabID = racedSession?.tabID
      },
      advance: {
        guard let racedSession else { return true }
        if racedSession.hasBrowser, racedSession.browserCreationCount == 1 {
          browserArrived = true
        }
        guard browserArrived else { return false }
        // One extra tick, so the focus request the selection transition queued
        // and this session's OnAfterCreated have both been delivered.
        ticksAfterArrival += 1
        return ticksAfterArrival >= 2
      },
      finish: { completed in
        let raced = racedSession
        self.report(
          "late-browser-creation-keeps-focus",
          completed && browserArrived && browserWasPendingWhenDeselected && keptHeldKeyboard
            && raced != nil
            && raced?.isSurfaceVisible == false
            && raced?.holdsAppKitKeyboardFocus == false
            && self.manager.selectedTabID == keptTabID
            && self.manager.selectedSession?.holdsAppKitKeyboardFocus == keptHeldKeyboard,
          "browser-pending-when-deselected=\(browserWasPendingWhenDeselected) raced=[\(self.focusDescription(of: raced))] selected=[\(self.focusDescription(of: self.manager.selectedSession))]")
      })
  }

  /// Closing a background tab (the sidebar close button) leaves the active tab's
  /// keyboard ownership alone.
  private func backgroundCloseKeepsKeyboard() -> Step {
    var victim: BrowserSession?
    var selectedBefore: UUID?
    var heldBefore = false
    return Step(
      name: "background-close-keeps-keyboard",
      timeout: 90,
      begin: {
        selectedBefore = self.manager.selectedTabID
        self.manager.selectedSession?.focusPage()
        heldBefore = self.manager.selectedSession?.holdsAppKitKeyboardFocus ?? false
        // Prefer the tab the race phase left behind; otherwise any tab that is
        // not selected.
        let background =
          self.manager.tabs.map(\.id).first { $0 == self.racedTabID && $0 != selectedBefore }
          ?? self.manager.tabs.map(\.id).first { $0 != selectedBefore }
        if let background {
          victim = self.manager.session(for: background)
          self.manager.closeTab(id: background)
        }
      },
      advance: { victim?.isClosed ?? true },
      finish: { completed in
        self.report(
          "background-close-keeps-focus",
          completed && victim != nil && heldBefore
            && self.manager.selectedTabID == selectedBefore
            && self.manager.selectedSession?.holdsAppKitKeyboardFocus == true,
          "closed=[\(self.focusDescription(of: victim))] selected=[\(self.focusDescription(of: self.manager.selectedSession))]")
      })
  }

  /// Closing the selected tab (Cmd-W) hands the keyboard to the tab that becomes
  /// selected, instead of leaving first responder empty.
  private func closeSelectedTransfersKeyboard() -> Step {
    var closedID: UUID?
    var heldBefore = false
    return Step(
      name: "close-selected-transfers-keyboard",
      timeout: 90,
      begin: {
        closedID = self.manager.selectedTabID
        self.manager.selectedSession?.focusPage()
        heldBefore = self.manager.selectedSession?.holdsAppKitKeyboardFocus ?? false
        self.manager.closeSelectedTab()
      },
      advance: {
        guard let closedID, let selectedID = self.manager.selectedTabID,
          selectedID != closedID
        else { return false }
        // Wait until the closing session is really released, so the neighbour's
        // keyboard ownership is not observed while its predecessor is still
        // being torn down.
        guard self.manager.session(for: closedID) == nil else { return false }
        return self.manager.selectedSession?.holdsAppKitKeyboardFocus == true
      },
      finish: { completed in
        let released = closedID.map { self.manager.session(for: $0) == nil } ?? false
        self.report(
          "selected-close-transfers-focus",
          completed && heldBefore && released && self.manager.selectedTabID != closedID
            && self.manager.selectedSession?.holdsAppKitKeyboardFocus == true,
          "closed=\(self.shortID(closedID)) released=\(released) selected=[\(self.focusDescription(of: self.manager.selectedSession))]")
      })
  }

  /// Tab-sized focus diagnostics: identifiers, selection, visibility and whether
  /// AppKit's first responder is inside the session's surface. Never a URL, page
  /// text or anything the user typed (section 15).
  private func focusDescription(of session: BrowserSession?) -> String {
    guard let session else { return "tab=none" }
    return
      "tab=\(self.shortID(session.tabID)) selected=\(self.manager.selectedTabID == session.tabID) visible=\(session.isSurfaceVisible) focused=\(session.holdsAppKitKeyboardFocus) browser=\(session.hasBrowser)"
  }

  private func shortID(_ id: UUID?) -> String {
    guard let id else { return "none" }
    return String(id.uuidString.prefix(8))
  }

  /// True while AppKit's first responder is the native address field (or the
  /// shared field editor it uses). Class checks only - the field's text is never
  /// read (section 15).
  private var addressFieldIsFirstResponder: Bool {
    guard let window = NSApp.windows.first(where: { $0.isVisible }),
      let responder = window.firstResponder
    else { return false }
    return responder is NSTextView || responder is NativeBrowserAddressField
  }

  /// The class of the view AppKit is currently giving the keyboard to. A class
  /// name only - never page text, a URL or anything the user typed (section 15).
  private func responderClassName() -> String {
    guard let window = NSApp.windows.first(where: { $0.isVisible }),
      let responder = window.firstResponder
    else { return "none" }
    return String(describing: type(of: responder))
  }

  private func closeBackgroundTab() -> Step {
    Step(
      name: "close-background-tab",
      timeout: 90,
      begin: {
        // A tab that is not selected, so the close exercises the path that must
        // not steal focus (section 17).
        let background = self.manager.tabs.map(\.id).filter { $0 != self.manager.selectedTabID }
        guard let victim = background.first else { return }
        self.victimTabID = victim
        self.victimSession = self.manager.session(for: victim)
        self.survivors = self.manager.liveSessions.filter { $0.tabID != victim }
        self.manager.closeTab(id: victim)
      },
      advance: { self.victimSession?.isClosed ?? false },
      finish: { completed in
        self.report(
          "single-tab-close", completed,
          "isClosed=\(self.victimSession?.isClosed ?? false)")
        let alive = self.survivors.allSatisfy { !$0.isClosed && $0.hasBrowser }
        self.report(
          "other-browsers-alive",
          alive && self.manager.liveSessions.count == self.survivors.count,
          "alive=\(self.survivors.filter { !$0.isClosed }.count)/\(self.survivors.count) live=\(self.manager.liveSessions.count) tabs=\(self.manager.tabs.count)"
        )
      })
  }

  private func navigateSurvivor() -> Step {
    Step(
      name: "navigate-survivor",
      timeout: 90,
      begin: {
        guard let navigator = self.survivors.first else { return }
        self.navigateURLChangesBefore = navigator.mainFrameURLChangeCount
        navigator.load(Self.navigationAfterClose)
      },
      advance: {
        guard let navigator = self.survivors.first else { return true }
        return navigator.url?.absoluteString == Self.navigationAfterClose.absoluteString
          && navigator.mainFrameURLChangeCount > self.navigateURLChangesBefore
      },
      finish: { completed in
        self.report(
          "remaining-browser-navigates", completed,
          "url=\(URLLogSanitizer.sanitized(self.survivors.first?.url))")
      })
  }

  private func createStressTabs() -> Step {
    Step(
      name: "create-stress-tabs",
      timeout: 300,
      begin: {
        var created: [BrowserSession] = []
        for url in Self.stressTabURLs {
          guard let tabID = self.manager.createTab(url: url),
            let session = self.manager.session(for: tabID)
          else { continue }
          created.append(session)
        }
        self.stressSessions = created
      },
      advance: {
        !self.stressSessions.isEmpty
          && self.stressSessions.allSatisfy { $0.browserCreationCount == 1 && $0.hasBrowser }
      },
      finish: { completed in
        let identifiers = self.stressSessions.compactMap { $0.browserIdentifier }
        self.observedBrowserIdentifiers.formUnion(identifiers)
        self.report(
          "stress-browsers-created",
          completed && identifiers.count == self.stressSessions.count,
          "browsers=\(self.stressSessions.count) creations=\(self.stressSessions.map { String($0.browserCreationCount) }.joined(separator: ","))"
        )
        self.report(
          "stress-distinct-identity",
          Set(identifiers).count == identifiers.count
            && identifiers.count == self.stressSessions.count,
          "browsers=\(identifiers.count) distinct=\(Set(identifiers).count)")
      })
  }

  private func closeStressTabs() -> Step {
    Step(
      name: "close-stress-tabs",
      timeout: 180,
      begin: {
        // Close them all first and wait once: N browsers close in parallel, so
        // this is not N sequential waits.
        for session in self.stressSessions {
          self.manager.closeTab(id: session.tabID)
        }
      },
      advance: { self.stressSessions.allSatisfy { $0.isClosed } },
      finish: { completed in
        self.report(
          "stress-all-closed", completed,
          "closed=\(self.stressSessions.filter { $0.isClosed }.count)/\(self.stressSessions.count)"
        )
      })
  }

  private func drainToLastTab() -> Step {
    Step(
      name: "drain-to-last-tab",
      timeout: 180,
      begin: {
        for tabID in self.manager.tabs.map(\.id).dropLast() {
          self.manager.closeTab(id: tabID)
        }
      },
      advance: { self.manager.tabs.count == 1 && self.manager.liveSessionCount == 1 },
      finish: { completed in
        self.lastTabID = self.manager.tabs.first?.id
        self.report(
          "reduced-to-one-tab", completed,
          "tabs=\(self.manager.tabs.count) live=\(self.manager.liveSessionCount)")
      })
  }

  private func closeLastTab() -> Step {
    Step(
      name: "close-last-tab",
      timeout: 180,
      begin: {
        guard let lastTabID = self.lastTabID else { return }
        self.manager.closeTab(id: lastTabID)
      },
      advance: {
        guard let currentID = self.manager.tabs.first?.id else { return false }
        return self.manager.tabs.count == 1 && currentID != self.lastTabID
          && self.manager.liveSessionCount == 1
          && self.manager.selectedTabID == currentID
          && (self.manager.selectedSession?.browserCreationCount ?? 0) == 1
      },
      finish: { completed in
        self.report(
          "last-tab-close-creates-replacement", completed,
          "tabs=\(self.manager.tabs.count) live=\(self.manager.liveSessionCount) replacement=\(completed)"
        )
        self.observedBrowserIdentifiers.formUnion(
          self.manager.liveSessions.compactMap { $0.browserIdentifier })
      })
  }

  private func closeEverything() -> Step {
    Step(
      name: "close-everything",
      timeout: 120,
      begin: {
        self.liveAtTermination = self.manager.liveSessionCount
        self.terminationStarted = Date()
        // The application's own termination path, not a private test shortcut.
        self.manager.requestCloseAllForTermination()
      },
      advance: { !self.manager.hasLiveSessions },
      finish: { completed in
        let seconds = Date().timeIntervalSince(self.terminationStarted)
        let live = self.manager.liveSessionCount
        self.report(
          "all-browsers-closed", completed && live == 0,
          "live=\(live) requested=\(self.liveAtTermination) seconds=\(String(format: "%.2f", seconds))"
        )
        let usedFallback = seconds >= ApplicationRuntime.browserShutdownTimeout
        self.report(
          "no-timeout-fallback", completed && !usedFallback,
          "fallback=\(usedFallback ? "yes" : "no") budget=\(String(format: "%.1f", ApplicationRuntime.browserShutdownTimeout))s"
        )
        // Section 10: termination must not create a replacement tab.
        let refused = self.manager.createTab(url: Self.afterTermination) == nil
        self.report(
          "termination-refuses-new-tabs", refused && !self.manager.hasLiveSessions,
          "refused=\(refused) live=\(self.manager.liveSessionCount)")
        // Section 9: no browser may still exist when CefShutdown runs.
        self.report(
          "onbeforeclose-before-cef-shutdown",
          live == 0 && !self.runtime.hasShutDownCEF,
          "live=\(live) cef-already-down=\(self.runtime.hasShutDownCEF)")
      })
  }

  private func shutCefDown() -> Step {
    Step(
      name: "shutdown-cef",
      timeout: 30,
      begin: {
        let live = self.manager.liveSessionCount
        self.runtime.shutdownCEF()
        self.runtime.record("selftest:m3:cef-shutdown(live=\(live))")
      },
      advance: { true },
      finish: { _ in
        self.report(
          "cef-shutdown-once",
          self.runtime.cefShutdownCount == 1 && !CEFProcessHost.isInitialized,
          "count=\(self.runtime.cefShutdownCount) initialized=\(CEFProcessHost.isInitialized)")
        self.finishRun()
      })
  }

  // MARK: - Reporting

  /// Reports one check. Every URL is passed through URLLogSanitizer by the
  /// caller: this output is captured into a log file and the test drives real
  /// navigation.
  private func report(_ name: String, _ passed: Bool, _ detail: String) {
    checks += 1
    if !passed { failures += 1 }
    print("tabs-self-test: \(passed ? "pass" : "FAIL") \(name) - \(detail)")
    runtime.record("selftest:m3:\(name)=\(passed)")
  }

  private func finishRun() {
    timer?.invalidate()
    timer = nil
    print(
      "tabs-self-test: checks=\(checks) failures=\(failures) distinct-browser-identities=\(observedBrowserIdentifiers.count)"
    )
    runtime.emitLifecycleTrace()
    // CEF is already down and no browser exists, so this is the same exit the
    // other self-tests take.
    exit(failures == 0 ? 0 : 2)
  }
}
