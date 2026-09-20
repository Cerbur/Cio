//
//  SpacesSelfTest.swift
//  NativeBrowser
//
//  Milestone 4 runtime/integration self-test. It runs in the real SwiftUI
//  application window and real CEF message loop, so every assertion observes
//  production workspace, session and surface ownership.
//

import AppKit
import Foundation

@MainActor
final class SpacesSelfTest {
  private static var active: SpacesSelfTest?

  @discardableResult
  static func installIfRequested(runtime: ApplicationRuntime) -> Bool {
    guard CommandLine.arguments.contains("--spaces-self-test")
      || CommandLine.arguments.contains("--tabs-self-test")
    else { return false }

    let test = SpacesSelfTest(runtime: runtime)
    active = test
    test.start()
    return true
  }

  private static let spaceTabURLs: [[URL]] = [
    [
      URL(string: "https://example.com/work-2")!,
      URL(string: "https://example.org/work-3")!,
    ],
    [
      URL(string: "https://example.com/personal-2")!,
      URL(string: "https://example.org/personal-3")!,
    ],
    [
      URL(string: "https://example.com/research-2")!,
      URL(string: "https://example.org/research-3")!,
    ],
  ]

  private static let backgroundNavigationURL = URL(string: "https://example.org/background-space-callback")!
  private static let popupURL = URL(string: "data:text/html,popup-from-source-space")!
  private static let restoreURL = URL(string: "data:text/html,restore-space-identity")!
  private static let selectedCloseURL = URL(string: "data:text/html,selected-close-focus")!

  private struct Step {
    let name: String
    let timeout: TimeInterval
    var begin: () -> Void = {}
    let advance: () -> Bool
    let finish: (_ completed: Bool) -> Void
  }

  private let runtime: ApplicationRuntime
  private let workspace: BrowserWorkspaceStore
  private let manager: BrowserSessionManager
  private var steps: [Step] = []
  private var stepIndex = 0
  private var didBeginStep = false
  private var stepDeadline = Date.distantPast
  private var timer: Timer?

  private var checks = 0
  private var failures = 0
  private var observedBrowserIdentifiers = Set<Int>()

  private var spaceIDs: [UUID] = []
  private var rememberedSelections: [UUID: UUID] = [:]
  private var initialTabID: UUID?
  private var initialSession: BrowserSession? {
    initialTabID.flatMap { manager.session(for: $0) }
  }

  private var activeSpaceID: UUID?
  private var focusSourceSpaceID: UUID?
  private var focusTargetSpaceID: UUID?
  private var keptFocusTabID: UUID?
  private var raceTabID: UUID?
  private var raceSpaceID: UUID?
  private var raceSession: BrowserSession?
  private var raceWasPendingWhenDeselected = false
  private var backgroundCreationTabID: UUID?
  private var backgroundCreationSession: BrowserSession?

  private var backgroundSourceSpaceID: UUID?
  private var backgroundSourceSession: BrowserSession?
  private var backgroundURLChangeCount = 0
  private var selectedBeforeBackgroundCallback: UUID?
  private var selectedTabBeforeBackgroundCallback: UUID?

  private var backgroundVictimSession: BrowserSession?
  private var backgroundVictimTabID: UUID?
  private var selectedCloseOldSession: BrowserSession?
  private var selectedCloseOldTabID: UUID?
  private var selectedCloseDidRequest = false
  private var closeSpaceID: UUID?
  private var closeLastOldTabID: UUID?
  private var closeLastReplacementTabID: UUID?
  private var closeLastActiveSpaceID: UUID?
  private var closeLastOtherCounts: [UUID: Int] = [:]

  private var restoreSpaceID: UUID?
  private var restoreOldTabID: UUID?
  private var restoreOldSession: BrowserSession?
  private var restoreOriginalIndex: Int?
  private var restoredTabID: UUID?

  private var popupSourceSpaceID: UUID?
  private var popupSourceSession: BrowserSession?
  private var popupTabID: UUID?
  private var popupActiveSpaceID: UUID?

  private var terminationStarted = Date()
  private var liveAtTermination = 0
  private var recentlyClosedBeforeTermination = 0
  private var terminationSessions: [BrowserSession] = []
  private var terminationCoordinator: ApplicationRuntime.Terminator?
  private var productionTerminationFinished = false

  private init(runtime: ApplicationRuntime) {
    self.runtime = runtime
    workspace = runtime.workspaceStore
    manager = workspace.sessionManager
  }

  private var isLegacyInvocation: Bool {
    CommandLine.arguments.contains("--tabs-self-test")
  }

  private var outputLabel: String {
    // Keep the M3 entry point usable for regression runs while the M4 command
    // exposes the stronger Space checks.
    isLegacyInvocation ? "tabs-self-test" : "spaces-self-test"
  }

  private func start() {
    steps = buildSteps()
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated {
        SpacesSelfTest.active?.tick()
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
      AppLog.session.error(
        "\(self.outputLabel): step \(step.name, privacy: .public) timed out")
    }
    step.finish(completed)
    stepIndex += 1
    didBeginStep = false
  }

  private func buildSteps() -> [Step] {
    [
      waitForInitialWorkspace(),
      createSpaces(),
      createTabsInEachSpace(),
      sameSpaceTabSwitchAndFocus(),
      addressFieldFocusSurvivesTabSwitch(),
      backgroundTabCreationIsolation(),
      rememberIndependentSelections(),
      switchSpacesWithoutRecreation(),
      selectedPageFocusMovesWithSpace(),
      addressFieldFocusSurvivesSpaceSwitch(),
      asynchronousSpaceCreationRace(),
      backgroundCallbackIsolation(),
      backgroundTabCloseIsolation(),
      selectedTabCloseTransfersFocus(),
      closeLastTabInInactiveSpace(),
      closeLastTabCreatesSameSpaceReplacement(),
      reopenClosedTabInOriginalSpace(),
      popupRoutesToSourceSpace(),
      terminateEverySpace(),
      shutCefDown(),
    ]
  }

  // MARK: - Workspace creation and selection

  private func waitForInitialWorkspace() -> Step {
    Step(
      name: "initial-workspace",
      timeout: 180,
      begin: {
        self.initialTabID = self.workspace.tabs.first?.id
      },
      advance: {
        guard let session = self.initialSession else { return false }
        return self.workspace.spaces.count == 1
          && self.workspace.selectedSpace?.name == "Main"
          && self.workspace.tabs.count == 1
          && self.workspace.selectedTabID == self.initialTabID
          && session.hasBrowser
      },
      finish: { completed in
        let initialTabSelected = self.workspace.selectedTabID == self.initialTabID
        self.report(
          "initial-workspace-one-space",
          completed && self.workspace.spaces.count == 1,
          "spaces=\(self.workspace.spaces.count)")
        self.report(
          "initial-space-selected",
          completed && self.workspace.selectedSpace?.name == "Main",
          "name=\(self.workspace.selectedSpace?.name ?? "none")")
        self.report(
          "initial-space-one-selected-tab",
          completed && self.workspace.tabs.count == 1 && initialTabSelected,
          "tabs=\(self.workspace.tabs.count) selected=\(initialTabSelected)")
      })
  }

  private func createSpaces() -> Step {
    Step(
      name: "create-spaces",
      timeout: 300,
      begin: {
        _ = self.workspace.createSpace()
        _ = self.workspace.createSpace()
        self.spaceIDs = self.workspace.spaces.map(\.id)
        self.activeSpaceID = self.spaceIDs.first
        if let first = self.activeSpaceID {
          self.workspace.selectSpace(id: first)
        }
      },
      advance: {
        guard self.spaceIDs.count == 3 else { return false }
        let sessions = self.manager.liveSessions
        return sessions.count == 3
          && self.spaceIDs.allSatisfy { self.workspace.tabs(in: $0).count == 1 }
          && sessions.allSatisfy { $0.hasBrowser && $0.browserCreationCount == 1 }
      },
      finish: { completed in
        let identifiers = self.manager.liveBrowserIdentifiers
        self.observedBrowserIdentifiers.formUnion(identifiers)
        self.report(
          "three-spaces-created",
          completed && self.workspace.spaces.count >= 3,
          "spaces=\(self.workspace.spaces.count)")
        self.report(
          "space-ids-unique",
          self.spaceIDs.count == Set(self.spaceIDs).count,
          "ids=\(self.spaceIDs.count)")
        self.report(
          "each-space-has-one-fresh-tab",
          completed && self.spaceIDs.allSatisfy { self.workspace.tabs(in: $0).count == 1 },
          "tabs=\(self.spaceIDs.map { self.workspace.tabs(in: $0).count })")
        self.report(
          "space-browsers-created",
          completed && identifiers.count == 3 && Set(identifiers).count == identifiers.count,
          "sessions=\(self.manager.liveSessions.count) browsers=\(identifiers.count)")
      })
  }

  private func createTabsInEachSpace() -> Step {
    Step(
      name: "create-tabs-in-each-space",
      timeout: 420,
      begin: {
        for (spaceIndex, spaceID) in self.spaceIDs.enumerated() {
          self.workspace.selectSpace(id: spaceID)
          for url in Self.spaceTabURLs[spaceIndex] {
            _ = self.workspace.createTab(url: url)
          }
        }
        if let first = self.spaceIDs.first {
          self.workspace.selectSpace(id: first)
        }
      },
      advance: {
        let expected = self.spaceIDs.count * 3
        return self.spaceIDs.count == 3
          && self.spaceIDs.allSatisfy { self.workspace.tabs(in: $0).count == 3 }
          && self.manager.liveSessions.count == expected
          && self.manager.liveSessions.allSatisfy { $0.hasBrowser && $0.browserCreationCount == 1 }
      },
      finish: { completed in
        let sessions = self.manager.liveSessions
        let identifiers = sessions.compactMap(\.browserIdentifier)
        self.observedBrowserIdentifiers.formUnion(identifiers)
        self.report(
          "multiple-tabs-per-space",
          completed && self.spaceIDs.allSatisfy { self.workspace.tabs(in: $0).count == 3 },
          "counts=\(self.spaceIDs.map { self.workspace.tabs(in: $0).count })")
        self.report(
          "distinct-space-browser-identities",
          completed && identifiers.count == sessions.count
            && Set(identifiers).count == identifiers.count,
          "sessions=\(sessions.count) distinct=\(Set(identifiers).count)")
        self.report(
          "all-existing-sessions-created-once",
          completed && sessions.allSatisfy { $0.browserCreationCount == 1 },
          "creations=\(sessions.map { $0.browserCreationCount })")
      })
  }

  /// Keeps the Milestone 3 same-Space tab-switch regression distinct from the
  /// new Space-switch checks. Every selected tab change must reuse its existing
  /// BrowserSession and move page focus only after the previous page releases it.
  private func sameSpaceTabSwitchAndFocus() -> Step {
    var order: [UUID] = []
    var creationCounts: [UUID: Int] = [:]
    var browserIDs: [UUID: Int] = [:]
    var switchCount = 0
    var pageFocusReady = false
    var focusTransferObserved = false
    var lastSwitch: (source: UUID, target: UUID)?

    return Step(
      name: "same-space-tab-switch",
      timeout: 180,
      begin: {
        guard let firstSpace = self.spaceIDs.first else { return }
        self.workspace.selectSpace(id: firstSpace)
        order = self.workspace.tabs(in: firstSpace).map(\.id)
        creationCounts = Dictionary(
          uniqueKeysWithValues: self.manager.liveSessions.map { ($0.tabID, $0.browserCreationCount) })
        browserIDs = Dictionary(
          uniqueKeysWithValues: self.manager.liveSessions.compactMap { session in
            session.browserIdentifier.map { (session.tabID, $0) }
          })
        self.workspace.selectedSession?.focusPage()
      },
      advance: {
        guard order.count >= 2 else { return false }
        if let lastSwitch,
          self.manager.session(for: lastSwitch.source)?.holdsAppKitKeyboardFocus == false,
          self.manager.session(for: lastSwitch.target)?.holdsAppKitKeyboardFocus == true
        {
          focusTransferObserved = true
        }
        if !pageFocusReady {
          pageFocusReady = self.workspace.selectedSession?.holdsAppKitKeyboardFocus == true
          if !pageFocusReady {
            self.workspace.selectedSession?.focusPage()
          }
          return false
        }
        guard switchCount < order.count * 3 else {
          return self.manager.liveSessions.allSatisfy { $0.url != nil }
        }
        let source = self.workspace.selectedTabID
        let target = order[(switchCount + 1) % order.count]
        self.workspace.selectTab(id: target)
        if let source, source != target {
          lastSwitch = (source: source, target: target)
        }
        switchCount += 1
        return false
      },
      finish: { completed in
        let sessions = self.manager.liveSessions
        let noRecreation = sessions.allSatisfy {
            creationCounts[$0.tabID] == $0.browserCreationCount
            && $0.browserCreationCount == 1
            && browserIDs[$0.tabID] == $0.browserIdentifier
        }
        let distinctURLs = self.spaceIDs.allSatisfy { spaceID in
          let tabs = self.workspace.tabs(in: spaceID)
          let urls = tabs.compactMap { $0.url?.absoluteString }
          return urls.count == tabs.count && Set(urls).count == tabs.count
        }
        let finalPageFocus = self.workspace.selectedSession?.holdsAppKitKeyboardFocus == true
        self.observedBrowserIdentifiers.formUnion(self.manager.liveBrowserIdentifiers)
        self.report(
          "selected-page-holds-keyboard",
          completed && pageFocusReady && finalPageFocus,
          self.focusDescription(of: self.workspace.selectedSession))
        self.report(
          "switch-moves-keyboard",
          completed && focusTransferObserved,
          "switches=\(switchCount) focused=\(focusTransferObserved)")
        self.report(
          "switch-does-not-recreate",
          completed && noRecreation,
          "switches=\(switchCount) creations-unchanged=\(noRecreation)")
        self.report(
          "distinct-urls",
          completed && distinctURLs,
          "spaces=\(self.spaceIDs.count) distinct-per-space=\(distinctURLs)")
      })
  }

  /// Preserves the M3 address-field rule for a selected tab change inside one
  /// Space. Space switching exercises the same transition later, but this
  /// check keeps the original tab-level coverage explicit.
  private func addressFieldFocusSurvivesTabSwitch() -> Step {
    var didRequestAddressFocus = false
    var createdTabID: UUID?
    var createdSession: BrowserSession?
    var ticksAfterBrowser = 0

    return Step(
      name: "tab-change-address-focus",
      timeout: 120,
      begin: {
        guard let firstSpace = self.spaceIDs.first else { return }
        self.workspace.selectSpace(id: firstSpace)
        self.workspace.selectedSession?.requestAddressFieldFocus()
      },
      advance: {
        if !didRequestAddressFocus {
          didRequestAddressFocus = self.addressFieldIsFirstResponder
          return false
        }
        if createdTabID == nil {
          createdTabID = self.workspace.createTab(
            url: URL(string: "https://example.com/focus-address-field"))
          createdSession = createdTabID.flatMap { self.manager.session(for: $0) }
          return false
        }
        guard let createdSession else { return false }
        guard createdSession.hasBrowser, createdSession.browserCreationCount == 1 else {
          return false
        }
        ticksAfterBrowser += 1
        return ticksAfterBrowser >= 2
      },
      finish: { completed in
        let pageFocused = self.manager.liveSessions.contains { $0.holdsAppKitKeyboardFocus }
        self.report(
          "tab-change-keeps-address-focus",
          completed && self.workspace.selectedTabID == createdTabID
            && self.addressFieldIsFirstResponder && !pageFocused,
          "created=\(self.shortID(createdTabID)) selected=\(self.shortID(self.workspace.selectedTabID)) field-editor=\(self.addressFieldIsFirstResponder) any-page-focused=\(pageFocused)")
      })
  }

  /// Creates an explicitly background tab in the selected Space and waits for
  /// its real browser to arrive. Its late creation must not change selection or
  /// steal the selected page's keyboard ownership.
  private func backgroundTabCreationIsolation() -> Step {
    var selectedBefore: UUID?
    var heldBefore = false
    var ticks = 0
    var browserArrivedAtTick: Int?
    var focusAppearedAtTick: Int?

    return Step(
      name: "background-tab-creation",
      timeout: 120,
      begin: {
        guard let firstSpace = self.spaceIDs.first else { return }
        self.workspace.selectSpace(id: firstSpace)
        selectedBefore = self.workspace.selectedTabID
        self.workspace.selectedSession?.focusPage()
        heldBefore = self.workspace.selectedSession?.holdsAppKitKeyboardFocus == true
        self.backgroundCreationTabID = self.workspace.createTab(
          url: URL(string: "https://example.com/focus-background"),
          in: firstSpace,
          select: false)
        self.backgroundCreationSession = self.backgroundCreationTabID.flatMap {
          self.manager.session(for: $0)
        }
      },
      advance: {
        ticks += 1
        guard let session = self.backgroundCreationSession else { return false }
        if session.hasBrowser, session.browserCreationCount == 1,
          browserArrivedAtTick == nil
        {
          browserArrivedAtTick = ticks
        }
        if focusAppearedAtTick == nil, session.holdsAppKitKeyboardFocus {
          focusAppearedAtTick = ticks
        }
        guard let browserArrivedAtTick else { return false }
        return ticks >= browserArrivedAtTick + 2
      },
      finish: { completed in
        let background = self.backgroundCreationSession
        let focusTick = focusAppearedAtTick.map(String.init) ?? "never"
        self.report(
          "background-creation-keeps-selection",
          completed && background != nil && self.workspace.selectedTabID == selectedBefore,
          "selected-before=\(self.shortID(selectedBefore)) selected-after=\(self.shortID(self.workspace.selectedTabID))")
        self.report(
          "background-browser-does-not-take-focus",
          completed && heldBefore && background != nil
            && background?.holdsAppKitKeyboardFocus == false
            && background?.isSurfaceVisible == false
            && self.workspace.selectedSession?.holdsAppKitKeyboardFocus == heldBefore,
          "background=[\(self.focusDescription(of: background))] browser-tick=\(browserArrivedAtTick.map(String.init) ?? "never") focus-tick=\(focusTick)")
      })
  }

  private func rememberIndependentSelections() -> Step {
    Step(
      name: "remember-independent-selections",
      timeout: 60,
      begin: {
        self.rememberedSelections.removeAll()
        for spaceID in self.spaceIDs {
          self.workspace.selectSpace(id: spaceID)
          if let tabID = self.workspace.tabs(in: spaceID).last?.id {
            self.workspace.selectTab(id: tabID)
            self.rememberedSelections[spaceID] = tabID
          }
        }
        if let first = self.spaceIDs.first {
          self.workspace.selectSpace(id: first)
          self.activeSpaceID = first
        }
      },
      advance: {
        self.spaceIDs.allSatisfy { spaceID in
          self.workspace.space(withID: spaceID)?.selectedTabID == self.rememberedSelections[spaceID]
        }
      },
      finish: { completed in
        self.report(
          "independent-space-selections",
          completed && self.rememberedSelections.count == self.spaceIDs.count,
          "remembered=\(self.rememberedSelections.count)")
      })
  }

  private func switchSpacesWithoutRecreation() -> Step {
    var switches = 0
    var creationCounts: [UUID: Int] = [:]
    var browserIDs: [UUID: Int] = [:]
    return Step(
      name: "switch-spaces-without-recreation",
      timeout: 120,
      begin: {
        switches = 0
        creationCounts = Dictionary(
          uniqueKeysWithValues: self.manager.liveSessions.map { ($0.tabID, $0.browserCreationCount) })
        browserIDs = Dictionary(
          uniqueKeysWithValues: self.manager.liveSessions.compactMap { session in
            session.browserIdentifier.map { (session.tabID, $0) }
          })
      },
      advance: {
        guard !self.spaceIDs.isEmpty else { return false }
        guard switches < self.spaceIDs.count * 5 else { return true }
        let target = self.spaceIDs[switches % self.spaceIDs.count]
        self.workspace.selectSpace(id: target)
        switches += 1
        return false
      },
      finish: { completed in
        let visible = self.manager.liveSessions.filter(\.isSurfaceVisible)
        let allCreationCountsUnchanged = self.manager.liveSessions.allSatisfy {
          creationCounts[$0.tabID] == $0.browserCreationCount && $0.browserCreationCount == 1
        }
        let allBrowserIDsUnchanged = self.manager.liveSessions.allSatisfy {
          browserIDs[$0.tabID] == $0.browserIdentifier
        }
        let correctSelection = self.spaceIDs.allSatisfy { spaceID in
          self.workspace.space(withID: spaceID)?.selectedTabID == self.rememberedSelections[spaceID]
        }
        let oneVisible = visible.count == 1
          && visible.first?.tabID == self.workspace.selectedTabID
        self.observedBrowserIdentifiers.formUnion(self.manager.liveBrowserIdentifiers)
        self.report(
          "switch-spaces-restores-remembered-tabs",
          completed && correctSelection,
          "switches=\(switches) remembered=\(correctSelection)")
        self.report(
          "switch-spaces-does-not-recreate",
          completed && allCreationCountsUnchanged && allBrowserIDsUnchanged,
          "creation-counts-unchanged=\(allCreationCountsUnchanged) browser-ids-unchanged=\(allBrowserIDsUnchanged)")
        self.report(
          "only-selected-space-tab-is-visible",
          completed && oneVisible,
          "visible=\(visible.count) selected=\(self.shortID(self.workspace.selectedTabID))")
      })
  }

  // MARK: - Focus and background isolation

  private func selectedPageFocusMovesWithSpace() -> Step {
    Step(
      name: "space-focus-transition",
      timeout: 60,
      begin: {
        self.focusSourceSpaceID = self.spaceIDs.first
        self.focusTargetSpaceID = self.spaceIDs.dropFirst().first
        if let source = self.focusSourceSpaceID {
          self.workspace.selectSpace(id: source)
          self.workspace.selectedSession?.focusPage()
        }
      },
      advance: {
        guard let source = self.focusSourceSpaceID,
          let target = self.focusTargetSpaceID,
          let sourceTab = self.rememberedSelections[source],
          let targetTab = self.rememberedSelections[target]
        else { return false }
        if self.workspace.selectedSpaceID == source
          && self.workspace.selectedTabID == sourceTab
          && self.workspace.selectedSession?.holdsAppKitKeyboardFocus == true
        {
          self.workspace.selectSpace(id: target)
        }
        return self.workspace.selectedSpaceID == target
          && self.workspace.selectedTabID == targetTab
          && self.manager.session(for: sourceTab)?.holdsAppKitKeyboardFocus == false
          && self.manager.session(for: targetTab)?.holdsAppKitKeyboardFocus == true
      },
      finish: { completed in
        self.report(
          "space-switch-moves-page-focus",
          completed,
          "source=\(self.shortID(self.focusSourceSpaceID)) target=\(self.shortID(self.focusTargetSpaceID))")
      })
  }

  private func addressFieldFocusSurvivesSpaceSwitch() -> Step {
    var didRequestAddressFocus = false
    return Step(
      name: "space-switch-address-focus",
      timeout: 90,
      begin: {
        self.workspace.selectedSession?.requestAddressFieldFocus()
      },
      advance: {
        if !didRequestAddressFocus {
          didRequestAddressFocus = self.addressFieldIsFirstResponder
          return false
        }
        if let target = self.spaceIDs.last, self.workspace.selectedSpaceID != target {
          self.workspace.selectSpace(id: target)
          return false
        }
        let anyPageFocused = self.manager.liveSessions.contains { $0.holdsAppKitKeyboardFocus }
        return self.addressFieldIsFirstResponder && !anyPageFocused
      },
      finish: { completed in
        let noHiddenPageFocus = !self.manager.liveSessions.contains { $0.holdsAppKitKeyboardFocus }
        self.report(
          "address-field-owns-keyboard-before-space-switch",
          didRequestAddressFocus,
          "field-editor=\(didRequestAddressFocus)")
        self.report(
          "space-switch-does-not-steal-address-focus",
          completed && self.addressFieldIsFirstResponder && noHiddenPageFocus,
          "field-editor=\(self.addressFieldIsFirstResponder) any-page-focused=\(noHiddenPageFocus ? "no" : "yes")")
      })
  }

  private func asynchronousSpaceCreationRace() -> Step {
    var browserArrived = false
    var ticksAfterArrival = 0
    return Step(
      name: "async-space-tab-creation-race",
      timeout: 120,
      begin: {
        guard let source = self.spaceIDs.first else { return }
        self.workspace.selectSpace(id: source)
        self.workspace.selectedSession?.focusPage()
        self.keptFocusTabID = self.workspace.selectedTabID
        // A newly created Space is selected immediately, but its Chromium
        // browser is still created asynchronously. Switch back to Space A
        // before OnAfterCreated so the late callback cannot steal focus.
        self.raceSpaceID = self.workspace.createSpace()
        self.raceTabID = self.raceSpaceID.flatMap { self.workspace.tabs(in: $0).first?.id }
        self.raceSession = self.raceTabID.flatMap { self.manager.session(for: $0) }
        if let kept = self.keptFocusTabID {
          self.raceWasPendingWhenDeselected = self.raceSession != nil
            && self.raceSession?.hasBrowser == false
            && self.raceSession?.browserCreationCount == 0
          self.workspace.selectSpace(id: source)
          self.workspace.selectTab(id: kept)
        }
      },
      advance: {
        guard let session = self.raceSession else { return true }
        if session.hasBrowser && session.browserCreationCount == 1 {
          browserArrived = true
        }
        guard browserArrived else { return false }
        ticksAfterArrival += 1
        return ticksAfterArrival >= 2
      },
      finish: { completed in
        let race = self.raceSession
        let kept = self.keptFocusTabID
        self.report(
          "space-creation-race-was-async",
          completed && self.raceWasPendingWhenDeselected,
          "pending-when-deselected=\(self.raceWasPendingWhenDeselected)")
        self.report(
          "late-space-browser-stays-hidden",
          completed && race?.isSurfaceVisible == false && race?.holdsAppKitKeyboardFocus == false
            && self.workspace.selectedTabID == kept,
          "race=[\(self.focusDescription(of: race))] selected=\(self.shortID(self.workspace.selectedTabID))")
      })
  }

  private func backgroundCallbackIsolation() -> Step {
    Step(
      name: "background-callback-isolation",
      timeout: 60,
      begin: {
        guard let active = self.spaceIDs.first,
          let source = self.spaceIDs.dropFirst().first,
          let sourceTabID = self.workspace.tabs(in: source).first?.id,
          let sourceSession = self.manager.session(for: sourceTabID)
        else { return }
        self.workspace.selectSpace(id: active)
        self.activeSpaceID = active
        self.backgroundSourceSpaceID = source
        self.backgroundSourceSession = sourceSession
        self.backgroundURLChangeCount = sourceSession.mainFrameURLChangeCount
        self.selectedBeforeBackgroundCallback = self.workspace.selectedSpaceID
        self.selectedTabBeforeBackgroundCallback = self.workspace.selectedTabID
        sourceSession.load(Self.backgroundNavigationURL)
      },
      advance: {
        guard let session = self.backgroundSourceSession else { return false }
        return self.isBackgroundCallbackURL(session.url)
          && session.mainFrameURLChangeCount > self.backgroundURLChangeCount
      },
      finish: { completed in
        let selectionStayed = self.workspace.selectedSpaceID == self.selectedBeforeBackgroundCallback
          && self.workspace.selectedTabID == self.selectedTabBeforeBackgroundCallback
        let source = self.backgroundSourceSession
        self.report(
          "inactive-space-callback-updated-source-tab",
          completed && self.isBackgroundCallbackURL(source?.url),
          "callback-completed=\(completed)")
        self.report(
          "inactive-space-callback-keeps-selection",
          completed && selectionStayed && source?.isSurfaceVisible == false,
          "selection-stayed=\(selectionStayed) source-visible=\(source?.isSurfaceVisible ?? true)")
      })
  }

  private func backgroundTabCloseIsolation() -> Step {
    Step(
      name: "background-tab-close-isolation",
      timeout: 90,
      begin: {
        guard let active = self.spaceIDs.first,
          let source = self.spaceIDs.dropFirst().first,
          let victimID = self.workspace.tabs(in: source).first?.id,
          let victim = self.manager.session(for: victimID)
        else { return }
        self.workspace.selectSpace(id: active)
        self.activeSpaceID = active
        self.backgroundVictimTabID = victimID
        self.backgroundVictimSession = victim
        self.selectedBeforeBackgroundCallback = self.workspace.selectedSpaceID
        self.workspace.closeTab(id: victimID)
      },
      advance: {
        self.backgroundVictimSession?.isClosed ?? true
      },
      finish: { completed in
        let selectionStayed = self.workspace.selectedSpaceID == self.selectedBeforeBackgroundCallback
        let otherSpaceStillHasTabs = self.spaceIDs.dropFirst().allSatisfy {
          !self.workspace.tabs(in: $0).isEmpty
        }
        self.report(
          "background-close-only-removes-own-space-tab",
          completed && selectionStayed && otherSpaceStillHasTabs,
          "closed=\(completed) selection-stayed=\(selectionStayed)")
        self.report(
          "background-close-keeps-active-page-focus",
          completed && self.workspace.selectedSession?.isSurfaceVisible == true,
          "active=\(self.focusDescription(of: self.workspace.selectedSession))")
      })
  }

  private func selectedTabCloseTransfersFocus() -> Step {
    Step(
      name: "selected-tab-close-focus-transfer",
      timeout: 90,
      begin: {
        guard let active = self.spaceIDs.first,
          self.workspace.selectedTabID != nil
        else { return }
        self.workspace.selectSpace(id: active)
        let oldTabID = self.workspace.createTab(url: Self.selectedCloseURL, select: true)
          ?? self.workspace.selectedTabID
        guard let oldTabID,
          let oldSession = self.manager.session(for: oldTabID)
        else { return }
        self.selectedCloseOldTabID = oldTabID
        self.selectedCloseOldSession = oldSession
        self.selectedCloseDidRequest = false
        oldSession.focusPage()
      },
      advance: {
        guard let oldSession = self.selectedCloseOldSession,
          let oldTabID = self.selectedCloseOldTabID
        else { return false }
        if !self.selectedCloseDidRequest {
          guard self.workspace.selectedTabID == oldTabID else { return false }
          guard oldSession.holdsAppKitKeyboardFocus else {
            oldSession.focusPage()
            return false
          }
          self.selectedCloseDidRequest = true
          self.workspace.closeTab(id: oldTabID)
          return false
        }
        return self.workspace.selectedTabID != oldTabID
          && self.workspace.selectedSession?.holdsAppKitKeyboardFocus == true
      },
      finish: { completed in
        self.report(
          "selected-close-transfers-focus",
          completed,
          "old=\(self.shortID(self.selectedCloseOldTabID)) new=\(self.shortID(self.workspace.selectedTabID)) focused=\(self.workspace.selectedSession?.holdsAppKitKeyboardFocus == true)")
      })
  }

  // MARK: - Same-Space close/replacement

  private func closeLastTabInInactiveSpace() -> Step {
    Step(
      name: "close-space-to-one-tab",
      timeout: 120,
      begin: {
        guard let active = self.spaceIDs.first,
          let target = self.spaceIDs.dropFirst().first
        else { return }
        self.activeSpaceID = active
        self.closeSpaceID = target
        self.workspace.selectSpace(id: active)
        let ids = self.workspace.tabs(in: target).map(\.id)
        for tabID in ids.dropLast() {
          self.workspace.closeTab(id: tabID)
        }
      },
      advance: {
        guard let target = self.closeSpaceID else { return false }
        let tabIDs = self.workspace.tabs(in: target).map(\.id)
        return tabIDs.count == 1
          && self.workspace.selectedSpaceID == self.activeSpaceID
          && self.manager.liveSessions.count == self.workspace.allTabIDs.count
      },
      finish: { completed in
        let targetCount = self.closeSpaceID.map { self.workspace.tabs(in: $0).count } ?? 0
        self.report(
          "closing-tabs-affects-only-own-space",
          completed && targetCount == 1,
          "target-tabs=\(targetCount) active=\(self.shortID(self.workspace.selectedSpaceID))")
      })
  }

  private func closeLastTabCreatesSameSpaceReplacement() -> Step {
    Step(
      name: "close-last-tab-same-space",
      timeout: 120,
      begin: {
        guard let target = self.closeSpaceID,
          let oldID = self.workspace.tabs(in: target).first?.id
        else { return }
        self.closeLastOldTabID = oldID
        self.closeLastActiveSpaceID = self.workspace.selectedSpaceID
        self.closeLastOtherCounts = Dictionary(
          uniqueKeysWithValues: self.spaceIDs.map { ($0, self.workspace.tabs(in: $0).count) })
        self.workspace.closeTab(id: oldID)
      },
      advance: {
        guard let target = self.closeSpaceID,
          let oldID = self.closeLastOldTabID,
          let replacement = self.workspace.tabs(in: target).first?.id
        else { return false }
        self.closeLastReplacementTabID = replacement
        let replacementSession = self.manager.session(for: replacement)
        return self.workspace.tabs(in: target).count == 1
          && replacement != oldID
          && self.manager.session(for: oldID) == nil
          && replacementSession?.hasBrowser == true
          && replacementSession?.browserCreationCount == 1
      },
      finish: { completed in
        guard let target = self.closeSpaceID else {
          self.report("last-tab-replacement-stays-in-space", false, "missing target Space")
          return
        }
        let activeStayed = self.workspace.selectedSpaceID == self.closeLastActiveSpaceID
        let otherCountsStayed = self.spaceIDs.allSatisfy { id in
          id == target || self.workspace.tabs(in: id).count == self.closeLastOtherCounts[id]
        }
        self.report(
          "last-tab-replacement-stays-in-space",
          completed && activeStayed && otherCountsStayed,
          "replacement=\(self.shortID(self.closeLastReplacementTabID)) active-stayed=\(activeStayed)")
        self.report(
          "last-tab-replacement-created-once",
          completed && (self.closeLastReplacementTabID.flatMap { self.manager.session(for: $0)?.browserCreationCount } == 1),
          "creation-count=\(self.closeLastReplacementTabID.flatMap { self.manager.session(for: $0)?.browserCreationCount } ?? 0)")
      })
  }

  // MARK: - Recently closed and popup routing

  private func reopenClosedTabInOriginalSpace() -> Step {
    var stage = 0
    var createdURLTabID: UUID?
    return Step(
      name: "reopen-original-space",
      timeout: 120,
      begin: {
        guard let source = self.spaceIDs.first else { return }
        self.workspace.selectSpace(id: source)
        createdURLTabID = self.workspace.createTab(url: Self.restoreURL, select: false)
      },
      advance: {
        guard let createdURLTabID else { return false }
        if stage == 0 {
          guard let createdSession = self.manager.session(for: createdURLTabID) else {
            return false
          }
          guard createdSession.hasBrowser else { return false }
          self.restoreSpaceID = self.workspace.spaceID(forTabID: createdURLTabID)
          self.restoreOldTabID = createdURLTabID
          self.restoreOldSession = createdSession
          self.restoreOriginalIndex = self.restoreSpaceID.flatMap { spaceID in
            self.workspace.tabs(in: spaceID).firstIndex(where: { $0.id == createdURLTabID })
          }
          self.workspace.closeTab(id: createdURLTabID)
          stage = 1
          return false
        }
        if stage == 1 {
          if let other = self.spaceIDs.last {
            self.workspace.selectSpace(id: other)
          }
          self.restoredTabID = self.workspace.reopenLastClosedTab()
          stage = 2
          return false
        }
        guard let restoredTabID = self.restoredTabID,
          let restored = self.manager.session(for: restoredTabID),
          let restoreSpaceID = self.restoreSpaceID
        else { return false }
        return self.workspace.selectedSpaceID == restoreSpaceID
          && restoredTabID != createdURLTabID
          && self.workspace.spaceID(forTabID: restoredTabID) == restoreSpaceID
          && restored.hasBrowser
          && restored.browserCreationCount == 1
      },
      finish: { completed in
        let restoredID = self.restoredTabID
        let restoredSpace = restoredID.flatMap { self.workspace.spaceID(forTabID: $0) }
        let snapshotSpace = self.workspace.recentlyClosed.last?.spaceID
        let restoredIndex = restoredID.flatMap { restored in
          restoredSpace.flatMap { self.workspace.tabs(in: $0).firstIndex(where: { $0.id == restored }) }
        }
        self.report(
          "recently-closed-remembers-space",
          completed && restoredSpace == self.restoreSpaceID,
          "original=\(self.shortID(self.restoreSpaceID)) restored=\(self.shortID(restoredSpace)) snapshot=\(self.shortID(snapshotSpace))")
        self.report(
          "reopen-creates-new-runtime",
          completed && restoredID != self.restoreOldTabID
            && restoredID.flatMap { self.manager.session(for: $0)?.browserCreationCount } == 1,
          "old=\(self.shortID(self.restoreOldTabID)) new=\(self.shortID(restoredID))")
        self.report(
          "reopen-restores-original-index",
          completed && restoredIndex == self.restoreOriginalIndex,
          "original-index=\(self.restoreOriginalIndex.map(String.init) ?? "none") restored-index=\(restoredIndex.map(String.init) ?? "none")")
        self.report(
          "reopen-selects-original-space",
          completed && self.workspace.selectedSpaceID == self.restoreSpaceID,
          "selected=\(self.shortID(self.workspace.selectedSpaceID))")
      })
  }

  private func popupRoutesToSourceSpace() -> Step {
    Step(
      name: "popup-source-space-routing",
      timeout: 180,
      begin: {
        guard let active = self.spaceIDs.first,
          let source = self.spaceIDs.dropFirst().first,
          let sourceTabID = self.workspace.tabs(in: source).first?.id,
          let sourceSession = self.manager.session(for: sourceTabID)
        else { return }
        self.popupActiveSpaceID = active
        self.popupSourceSpaceID = source
        self.popupSourceSession = sourceSession
        self.workspace.selectSpace(id: active)
        // Exercise the production typed callback. CEF's OnBeforePopup feeds this
        // exact closure; invoking it here makes source-Space routing deterministic
        // without depending on a remote page's popup script.
        sourceSession.onOpenNewTabRequest?(sourceSession, Self.popupURL.absoluteString)
      },
      advance: {
        guard let source = self.popupSourceSpaceID,
          let tabID = self.workspace.tabs(in: source).first(where: { $0.url == Self.popupURL })?.id
        else { return false }
        self.popupTabID = tabID
        return self.manager.session(for: tabID)?.hasBrowser == true
      },
      finish: { completed in
        let sourceStayed = self.popupSourceSpaceID.flatMap { id in
          self.popupTabID.flatMap { self.workspace.spaceID(forTabID: $0) == id }
        } ?? false
        let activeStayed = self.workspace.selectedSpaceID == self.popupActiveSpaceID
        self.report(
          "popup-from-inactive-space-uses-source-space",
          completed && sourceStayed,
          "source=\(self.shortID(self.popupSourceSpaceID)) popup=\(self.shortID(self.popupTabID))")
        self.report(
          "inactive-popup-does-not-switch-space-or-focus",
          completed && activeStayed && self.popupTabID.flatMap { self.manager.session(for: $0)?.isSurfaceVisible == false } == true,
          "active=\(self.shortID(self.workspace.selectedSpaceID)) source-active=\(activeStayed)")
      })
  }

  // MARK: - Shutdown

  private func terminateEverySpace() -> Step {
    Step(
      name: "terminate-all-spaces",
      // This is only the self-test's external observation window. Production
      // termination has no timeout fallback: CefShutdown is reached only after
      // every typed OnBeforeClose callback has been observed.
      timeout: 300,
      begin: {
        self.liveAtTermination = self.manager.liveSessionCount
        self.terminationSessions = self.manager.liveSessions
        self.recentlyClosedBeforeTermination = self.workspace.recentlyClosed.count
        self.terminationStarted = Date()
        self.productionTerminationFinished = false
        self.terminationCoordinator = ApplicationRuntime.Terminator(runtime: self.runtime) { [weak self] in
          self?.productionTerminationFinished = true
        }
        self.terminationCoordinator?.start()
      },
      advance: {
        self.productionTerminationFinished
      },
      finish: { completed in
        let seconds = Date().timeIntervalSince(self.terminationStarted)
        let allClosed = self.terminationSessions.allSatisfy(\.isClosed)
        let refusedNewTab = self.workspace.createTab(url: URL(string: "https://example.com/after-termination")) == nil
        let noNewRecent = self.workspace.recentlyClosed.count == self.recentlyClosedBeforeTermination
        let trace = self.runtime.lifecycleTrace
        let browsersClosedIndex = trace.lastIndex(of: "termination:browsers-closed")
        let cefShutdownIndex = trace.firstIndex { $0.hasPrefix("cef:shutdown(") }
        let closeBeforeCef = browsersClosedIndex != nil && cefShutdownIndex != nil
          && browsersClosedIndex! < cefShutdownIndex!
        self.report(
          "all-spaces-shutdown-closes-every-runtime",
          completed && self.manager.liveSessionCount == 0 && allClosed,
          "requested=\(self.liveAtTermination) closed=\(self.terminationSessions.count) seconds=\(String(format: "%.2f", seconds))")
        self.report(
          "termination-creates-no-replacement-or-history",
          completed && refusedNewTab && noNewRecent,
          "new-tab-refused=\(refusedNewTab) recent-unchanged=\(noNewRecent)")
        self.report(
          "onbeforeclose-before-cef-shutdown",
          completed && closeBeforeCef,
          "live=\(self.manager.liveSessionCount) cef-down=\(self.runtime.hasShutDownCEF)")
        self.report(
          "shutdown-waits-for-onbeforeclose",
          completed && self.manager.liveSessionCount == 0 && closeBeforeCef
            && self.runtime.hasShutDownCEF,
          "seconds=\(String(format: "%.2f", seconds)) live=\(self.manager.liveSessionCount) ordered=\(closeBeforeCef)")
      })
  }

  private func shutCefDown() -> Step {
    Step(
      name: "shutdown-cef",
      timeout: 30,
      begin: {
        self.runtime.record("selftest:m4:cef-shutdown(live=\(self.manager.liveSessionCount))")
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

  // MARK: - Reporting/helpers

  private func report(_ name: String, _ passed: Bool, _ detail: String) {
    checks += 1
    if !passed { failures += 1 }
    let line = "\(outputLabel): \(passed ? "pass" : "FAIL") \(name) - \(detail)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    FileHandle.standardOutput.synchronizeFile()
    runtime.record("selftest:m4:\(name)=\(passed)")
  }

  private func shortID(_ id: UUID?) -> String {
    guard let id else { return "none" }
    return String(id.uuidString.prefix(8))
  }

  private func focusDescription(of session: BrowserSession?) -> String {
    guard let session else { return "tab=none" }
    return "tab=\(shortID(session.tabID)) selected=\(workspace.selectedTabID == session.tabID) visible=\(session.isSurfaceVisible) focused=\(session.holdsAppKitKeyboardFocus) browser=\(session.hasBrowser)"
  }

  private var addressFieldIsFirstResponder: Bool {
    guard let window = NSApp.windows.first(where: { $0.isVisible }),
      let responder = window.firstResponder
    else { return false }
    return responder is NSTextView || responder is NativeBrowserAddressField
  }

  private func isBackgroundCallbackURL(_ url: URL?) -> Bool {
    guard let url else { return false }
    return url.host == Self.backgroundNavigationURL.host
      && url.path == Self.backgroundNavigationURL.path
  }

  private func finishRun() {
    timer?.invalidate()
    timer = nil
    let summary =
      "\(outputLabel): checks=\(checks) failures=\(failures) spaces=\(workspace.spaces.count) tabs=\(workspace.allTabs.count) distinct-browser-identities=\(observedBrowserIdentifiers.count)\n"
    FileHandle.standardOutput.write(Data(summary.utf8))
    FileHandle.standardOutput.synchronizeFile()
    runtime.emitLifecycleTrace()
    exit(failures == 0 ? 0 : 2)
  }
}
