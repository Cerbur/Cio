//
//  SessionRestoreSelfTest.swift
//  NativeBrowser
//
//  Process-level Milestone 6 verifier. The shell launches this driver twice;
//  the seed and verify phases intentionally never share Swift objects.
//

import AppKit
import Foundation

@MainActor
final class SessionRestoreSelfTest {
  private static var active: SessionRestoreSelfTest?

  private enum Mode {
    case seed
    case verify
  }

  private struct Step {
    let name: String
    let timeout: TimeInterval
    var begin: () -> Void = {}
    let advance: () -> Bool
    let finish: (_ completed: Bool) -> Void
  }

  @discardableResult
  static func installIfRequested(runtime: ApplicationRuntime) -> Bool {
    guard let argument = CommandLine.arguments.first(where: {
      $0.hasPrefix("--session-restore-self-test=")
    }) else { return false }
    let mode: Mode
    switch argument.split(separator: "=", maxSplits: 1).last.map(String.init) {
    case "seed": mode = .seed
    case "verify": mode = .verify
    default:
      print("session-restore-self-test: invalid phase")
      exit(2)
    }

    let test = SessionRestoreSelfTest(runtime: runtime, mode: mode)
    active = test
    test.start()
    return true
  }

  private let runtime: ApplicationRuntime
  private let workspace: BrowserWorkspaceStore
  private let manager: BrowserSessionManager
  private let mode: Mode
  private var steps: [Step] = []
  private var stepIndex = 0
  private var didBeginStep = false
  private var stepDeadline = Date.distantPast
  private var timer: Timer?

  private var initialSelectedTabID: UUID?
  private var initialSession: BrowserSession?
  private var lazyTabID: UUID?
  private var lazyTabURL: URL?
  private var lazyTabSession: BrowserSession?
  private var inactiveSpaceID: UUID?
  private var inactiveSpaceSelectedTabID: UUID?
  private var lazySpaceOtherTabID: UUID?
  private var liveCountBeforeLazyClose = 0
  private var domainCountBeforeLazyClose = 0
  private var didRequestTermination = false

  private init(runtime: ApplicationRuntime, mode: Mode) {
    self.runtime = runtime
    workspace = runtime.workspaceStore
    manager = workspace.sessionManager
    self.mode = mode
  }

  private func start() {
    steps = mode == .seed ? buildSeedSteps() : buildVerifySteps()
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated {
        SessionRestoreSelfTest.active?.tick()
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
    step.finish(completed)
    stepIndex += 1
    didBeginStep = false
  }

  private func buildSeedSteps() -> [Step] {
    [
      waitForWindow(),
      seedWorkspace(),
      waitForSeedRuntimes(),
      finishSeed(),
    ]
  }

  private func buildVerifySteps() -> [Step] {
    [
      waitForWindow(),
      verifyStartupGraph(),
      activateLazyTab(),
      switchBackAndReuseTab(),
      activateLazySpace(),
      closeNeverInstantiatedTab(),
      finishVerify(),
    ]
  }

  private func waitForWindow() -> Step {
    Step(
      name: "window",
      timeout: 180,
      advance: { self.runtime.didAppearInWindow },
      finish: { completed in
        self.report("window-appeared", completed, "appeared=\(self.runtime.didAppearInWindow)")
      })
  }

  private func seedWorkspace() -> Step {
    Step(
      name: "seed-workspace",
      timeout: 60,
      begin: {
        let spaces = self.workspace.spaces
        guard let mainID = spaces.first?.id else { return }
        _ = self.workspace.renameSpace(id: mainID, name: "Main")
        _ = self.workspace.createTab(
          url: URL(string: "https://example.com/main-secondary"),
          select: false,
          title: "Main secondary")

        guard let workID = self.workspace.createSpace(name: "Work"),
          let personalID = self.workspace.createSpace(name: "Personal")
        else { return }

        self.workspace.selectSpace(id: workID)
        _ = self.workspace.createTab(
          url: URL(string: "https://example.com/work-secondary"),
          select: true,
          title: "Work secondary")
        self.workspace.selectSpace(id: personalID)
        _ = self.workspace.createTab(
          url: URL(string: "https://example.com/personal-secondary"),
          select: true,
          title: "Personal secondary")

        // Work is selected at shutdown, with a non-first selected tab. Every
        // Space has its own remembered selected tab.
        self.workspace.selectSpace(id: workID)
        self.runtime.workspaceStore.flushSessionPersistence()
        print(
          "session-restore-self-test: seeded graph=\(self.graphDescription()) selected-space=\(workID.uuidString)")
      },
      advance: {
        self.workspace.spaces.count == 3
          && self.workspace.spaces.allSatisfy { self.workspace.tabs(in: $0.id).count == 2 }
          && self.workspace.selectedSpace?.name == "Work"
          && self.workspace.selectedTabID == self.workspace.tabs(in: self.workspace.selectedSpaceID).last?.id
      },
      finish: { completed in
        self.report(
          "seeded-three-spaces-and-two-tabs",
          completed,
          "spaces=\(self.workspace.spaces.count) tabs=\(self.workspace.allTabs.count)")
      })
  }

  private func waitForSeedRuntimes() -> Step {
    Step(
      name: "seed-runtimes",
      timeout: 240,
      advance: {
        self.manager.liveSessionCount == self.workspace.allTabs.count
          && self.manager.liveSessions.allSatisfy { $0.hasBrowser }
      },
      finish: { completed in
        self.report(
          "seed-runtimes-created",
          completed,
          "domain-tabs=\(self.workspace.allTabs.count) live-sessions=\(self.manager.liveSessionCount)")
      })
  }

  private func finishSeed() -> Step {
    Step(
      name: "finish-seed",
      timeout: 10,
      begin: {
        self.runtime.workspaceStore.flushSessionPersistence()
        print(
          "session-restore-self-test: seed-persisted domain-tabs=\(self.workspace.allTabs.count) graph=\(self.graphDescription())")
        self.requestTermination()
      },
      advance: {
        self.runtime.hasShutDownCEF
      },
      finish: { completed in
        self.report("seed-clean-shutdown", completed, "cef-shutdown=\(self.runtime.hasShutDownCEF)")
      })
  }

  private func verifyStartupGraph() -> Step {
    Step(
      name: "verify-startup-graph",
      timeout: 30,
      begin: {
        self.initialSelectedTabID = self.workspace.selectedTabID
        self.initialSession = self.initialSelectedTabID.flatMap { self.manager.session(for: $0) }
        guard let selectedSpace = self.workspace.selectedSpace,
          let selectedTabID = self.workspace.selectedTabID
        else { return }

        self.lazyTabID = self.workspace.tabs(in: selectedSpace.id)
          .map(\.id)
          .first { self.manager.session(for: $0) == nil }
        self.lazyTabURL = self.lazyTabID.flatMap { self.workspace.tab(withID: $0)?.url }

        self.inactiveSpaceID = self.workspace.spaces
          .map(\.id)
          .first { $0 != selectedSpace.id }
        self.inactiveSpaceSelectedTabID = self.inactiveSpaceID.flatMap {
          self.workspace.space(withID: $0)?.selectedTabID
        }
        self.lazySpaceOtherTabID = self.inactiveSpaceID.flatMap { spaceID in
          self.workspace.tabs(in: spaceID).map(\.id).first {
            $0 != self.workspace.space(withID: spaceID)?.selectedTabID
          }
        }

        let namesAndOrderRestored = self.workspace.spaces.map(\.name)
          == ["Main", "Work", "Personal"]
        let selectionShapeRestored = self.workspace.spaces.count == 3
          && self.workspace.spaces.enumerated().allSatisfy { index, space in
            let tabs = self.workspace.tabs(in: space.id)
            guard tabs.count == 2 else { return false }
            let expectedSelectedTab = index == 0 ? tabs.first?.id : tabs.last?.id
            return space.selectedTabID == expectedSelectedTab
          }
        let selectedSpaceAndTabRestored = self.workspace.selectedSpace?.name == "Work"
          && self.workspace.selectedTab?.title == "Work secondary"
        let secondaryTabs = self.workspace.allTabs.filter { $0.title.hasSuffix("secondary") }
        let secondaryTitlesRestored = Set(secondaryTabs.map(\.title)) == Set([
          "Main secondary", "Work secondary", "Personal secondary",
        ])
        let secondaryURLsRestored = Set(secondaryTabs.compactMap { $0.url?.path }) == Set([
          "/main-secondary", "/work-secondary", "/personal-secondary",
        ])
        let initialURLsRestored = self.workspace.spaces.allSatisfy { space in
          guard let url = self.workspace.tabs(in: space.id).first?.url else { return false }
          return url.scheme == "https"
            && url.host == "example.com"
            && url.query?.hasPrefix("code=") == true
            && url.fragment == "fragment-secret"
        }

        let startupGraphOK = self.workspace.allTabs.count > 1
          && self.manager.liveSessionCount == 1
          && self.initialSelectedTabID == selectedTabID
          && self.initialSession != nil
          && self.lazyTabID != nil
          && self.workspace.spaces.allSatisfy { $0.selectedTabID != nil }
        self.report(
          "startup-restored-domain-before-lazy-activation",
          startupGraphOK,
          "spaces=\(self.workspace.spaces.count) domain-tabs=\(self.workspace.allTabs.count) live-sessions=\(self.manager.liveSessionCount)")
        self.report(
          "startup-selected-tab-only-runtime",
          self.manager.liveSessionCount == 1
            && self.lazyTabID.map { self.manager.session(for: $0) == nil } == true,
          "selected=\(selectedTabID.uuidString) lazy=\(self.lazyTabID?.uuidString ?? "none")")
        self.report(
          "startup-space-order-and-selections-restored",
          namesAndOrderRestored && selectionShapeRestored && selectedSpaceAndTabRestored,
          "names-and-selection-shape=\(namesAndOrderRestored && selectionShapeRestored) selected-space=\(selectedSpaceAndTabRestored)")
        self.report(
          "startup-urls-and-titles-restored",
          secondaryTitlesRestored && secondaryURLsRestored && initialURLsRestored,
          "secondary-titles=\(secondaryTitlesRestored) secondary-urls=\(secondaryURLsRestored) initial-urls=\(initialURLsRestored)")
        print(
          "session-restore-self-test: restored graph=\(self.graphDescription()) selected-space=\(self.workspace.selectedSpaceID.uuidString)")
      },
      advance: {
        self.runtime.didAppearInWindow
          && self.manager.liveSessionCount == 1
          && self.initialSession?.hasBrowser == true
      },
      finish: { completed in
        self.report("startup-selected-browser-ready", completed, "ready=\(completed)")
      })
  }

  private func activateLazyTab() -> Step {
    Step(
      name: "lazy-tab",
      timeout: 180,
      begin: {
        guard let lazyTabID = self.lazyTabID else { return }
        self.report(
          "lazy-tab-had-no-session-before-selection",
          self.manager.session(for: lazyTabID) == nil,
          "tab=\(lazyTabID.uuidString)")
        self.workspace.selectTab(id: lazyTabID)
      },
      advance: {
        guard let lazyTabID = self.lazyTabID,
          let lazyTabURL = self.lazyTabURL,
          let session = self.manager.session(for: lazyTabID)
        else { return false }
        self.lazyTabSession = session
        return self.workspace.selectedTabID == lazyTabID
          && session.hasBrowser
          && session.browserCreationCount == 1
          && session.initialURL == lazyTabURL
          && session.hasFinishedFirstLoad
          && session.url == lazyTabURL
      },
      finish: { completed in
        self.report(
          "lazy-tab-created-on-first-activation",
          completed,
          "live-sessions=\(self.manager.liveSessionCount) browser-creations=\(self.lazyTabSession?.browserCreationCount ?? 0)")
      })
  }

  private func switchBackAndReuseTab() -> Step {
    Step(
      name: "reuse-tab",
      timeout: 30,
      begin: {
        if let initialSelectedTabID = self.initialSelectedTabID {
          self.workspace.selectTab(id: initialSelectedTabID)
        }
      },
      advance: {
        guard let initialSelectedTabID = self.initialSelectedTabID,
          let initialSession = self.initialSession,
          let lazyTabID = self.lazyTabID,
          let lazyTabSession = self.lazyTabSession
        else { return false }
        return self.workspace.selectedTabID == initialSelectedTabID
          && self.manager.session(for: initialSelectedTabID) === initialSession
          && self.manager.session(for: lazyTabID) === lazyTabSession
          && initialSession.browserCreationCount == 1
          && lazyTabSession.browserCreationCount == 1
          && self.manager.liveSessionCount == 2
      },
      finish: { completed in
        self.report(
          "switching-back-reuses-both-sessions",
          completed,
          "live-sessions=\(self.manager.liveSessionCount)")
      })
  }

  private func activateLazySpace() -> Step {
    Step(
      name: "lazy-space",
      timeout: 180,
      begin: {
        guard let inactiveSpaceID = self.inactiveSpaceID else { return }
        self.report(
          "lazy-space-selected-tab-had-no-session",
          self.inactiveSpaceSelectedTabID.map { self.manager.session(for: $0) == nil } == true,
          "space=\(inactiveSpaceID.uuidString)")
        self.workspace.selectSpace(id: inactiveSpaceID)
      },
      advance: {
        guard let inactiveSpaceID = self.inactiveSpaceID,
          let selectedTabID = self.inactiveSpaceSelectedTabID,
          let session = self.manager.session(for: selectedTabID)
        else { return false }
        return self.workspace.selectedSpaceID == inactiveSpaceID
          && self.workspace.selectedTabID == selectedTabID
          && session.hasBrowser
          && session.browserCreationCount == 1
          && session.hasFinishedFirstLoad
          && session.url == self.workspace.tab(withID: selectedTabID)?.url
          && self.lazySpaceOtherTabID.map { self.manager.session(for: $0) == nil } == true
      },
      finish: { completed in
        self.report(
          "lazy-space-instantiates-only-remembered-tab",
          completed,
          "live-sessions=\(self.manager.liveSessionCount) other-tab-session=\(self.lazySpaceOtherTabID.flatMap { self.manager.session(for: $0) } != nil)")
      })
  }

  private func closeNeverInstantiatedTab() -> Step {
    Step(
      name: "close-lazy-tab",
      timeout: 30,
      begin: {
        guard let lazySpaceOtherTabID = self.lazySpaceOtherTabID else { return }
        self.liveCountBeforeLazyClose = self.manager.liveSessionCount
        self.domainCountBeforeLazyClose = self.workspace.allTabs.count
        self.workspace.closeTab(id: lazySpaceOtherTabID)
      },
      advance: {
        guard let lazySpaceOtherTabID = self.lazySpaceOtherTabID else { return false }
        return self.workspace.tab(withID: lazySpaceOtherTabID) == nil
          && self.manager.session(for: lazySpaceOtherTabID) == nil
          && self.manager.liveSessionCount == self.liveCountBeforeLazyClose
          && self.workspace.allTabs.count == self.domainCountBeforeLazyClose - 1
      },
      finish: { completed in
        self.report(
          "closing-lazy-tab-does-not-create-runtime",
          completed,
          "domain-tabs=\(self.workspace.allTabs.count) live-sessions=\(self.manager.liveSessionCount)")
      })
  }

  private func finishVerify() -> Step {
    Step(
      name: "finish-verify",
      timeout: 10,
      begin: {
        self.runtime.workspaceStore.flushSessionPersistence()
        print(
          "session-restore-self-test: verify-before-shutdown domain-tabs=\(self.workspace.allTabs.count) live-sessions=\(self.manager.liveSessionCount) graph=\(self.graphDescription())")
        self.requestTermination()
      },
      advance: {
        self.runtime.hasShutDownCEF
      },
      finish: { completed in
        self.report(
          "verify-clean-shutdown",
          completed,
          "cef-shutdown=\(self.runtime.hasShutDownCEF) live-sessions=\(self.manager.liveSessionCount)")
      })
  }

  private func requestTermination() {
    guard !didRequestTermination else { return }
    didRequestTermination = true
    NSApp.terminate(nil)
  }

  private func report(_ name: String, _ passed: Bool, _ details: String) {
    let result = passed ? "pass" : "FAIL"
    print("session-restore-self-test: \(result) \(name) \(details)")
  }

  private func graphDescription() -> String {
    workspace.spaces.map { space in
      "\(space.id.uuidString)[\(space.tabIDs.map(\.uuidString).joined(separator: ","))]"
    }.joined(separator: ";")
  }
}
