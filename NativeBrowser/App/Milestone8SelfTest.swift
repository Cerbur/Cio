//
//  Milestone8SelfTest.swift
//  NativeBrowser
//
//  Bounded lifecycle and lazy-restore stress driver. It uses the production
//  workspace/session owners and the real CEF message pump; the shell verifier
//  supplies the external watchdog.
//

import AppKit
import Foundation

@MainActor
final class Milestone8SelfTest {
  private static var active: Milestone8SelfTest?

  private enum Phase {
    case stress
    case lazySeed
    case lazyVerify
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
    let prefix = "--milestone8-self-test="
    guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) })
    else { return false }

    let phase: Phase
    switch String(argument.dropFirst(prefix.count)) {
    case "stress": phase = .stress
    case "lazy-seed": phase = .lazySeed
    case "lazy-verify": phase = .lazyVerify
    default:
      print("m8-self-test: invalid phase")
      exit(2)
    }

    let test = Milestone8SelfTest(runtime: runtime, phase: phase)
    active = test
    test.start()
    return true
  }

  private let runtime: ApplicationRuntime
  private let workspace: BrowserWorkspaceStore
  private let manager: BrowserSessionManager
  private let phase: Phase
  private var window: NSWindow?
  private var steps: [Step] = []
  private var stepIndex = 0
  private var didBeginStep = false
  private var stepDeadline = Date.distantPast
  private var timer: Timer?
  private var terminationCoordinator: ApplicationRuntime.Terminator?
  private var terminationFinished = false
  private var stressSpaceIDs: [UUID] = []
  private var stressCreationCounts: [UUID: Int] = [:]
  private var closeIDs: [UUID] = []
  private var keptTabID: UUID?
  private var activatedLazyTabIDs: [UUID] = []
  private var checks = 0
  private var failures = 0

  private init(runtime: ApplicationRuntime, phase: Phase) {
    self.runtime = runtime
    workspace = runtime.workspaceStore
    manager = workspace.sessionManager
    self.phase = phase
  }

  private func start() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "NativeBrowser Milestone 8 self-test"
    let host = BrowserSurfaceHostView(frame: window.contentLayoutRect)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    window.orderBack(nil)
    self.window = window
    runtime.startMessagePump()
    workspace.attachSurfaceHost(host)

    switch phase {
    case .stress:
      steps = stressSteps()
    case .lazySeed:
      steps = lazySeedSteps()
    case .lazyVerify:
      steps = lazyVerifySteps()
    }

    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated {
        Milestone8SelfTest.active?.tick()
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
      print("m8-self-test: timeout \(step.name)")
    }
    step.finish(completed)
    stepIndex += 1
    didBeginStep = false
  }

  private func stressSteps() -> [Step] {
    [
      waitForInitialBrowser(),
      createStressGraph(),
      waitForStressBrowsers(),
      rapidlySwitchTabsAndSpaces(),
      closeBackgroundTabsAndReopen(),
      exercisePanelLifetime(),
      terminate(),
    ]
  }

  private func lazySeedSteps() -> [Step] {
    [
      waitForInitialBrowser(),
      createLazyGraph(),
      persistLazyGraph(),
      terminate(),
    ]
  }

  private func lazyVerifySteps() -> [Step] {
    [
      waitForInitialBrowser(),
      verifyLazyStartup(),
      activateLazySpaces(),
      exercisePanelLifetime(),
      terminate(),
    ]
  }

  private func waitForInitialBrowser() -> Step {
    Step(
      name: "initial-browser",
      timeout: 180,
      advance: { self.workspace.selectedSession?.hasBrowser == true },
      finish: { completed in
        self.report(
          "initial-browser-ready",
          completed,
          "live=\(self.manager.liveSessionCount)")
      })
  }

  private func createStressGraph() -> Step {
    Step(
      name: "create-stress-graph",
      timeout: 120,
      begin: {
        self.ensureSpaceCount(5)
        self.addTabsUntilEachSpaceHas(4, prefix: "stress")
        self.stressSpaceIDs = self.workspace.spaces.map(\.id)
        if let firstSpace = self.stressSpaceIDs.first {
          self.workspace.selectSpace(id: firstSpace)
          self.workspace.selectTab(id: self.workspace.tabs(in: firstSpace).first!.id)
        }
      },
      advance: {
        self.workspace.spaces.count >= 5
          && self.workspace.allTabs.count >= 20
          && self.manager.liveSessionCount == self.workspace.allTabs.count
      },
      finish: { completed in
        self.report(
          "twenty-tabs-five-spaces-created",
          completed,
          "tabs=\(self.workspace.allTabs.count) spaces=\(self.workspace.spaces.count) live=\(self.manager.liveSessionCount)")
      })
  }

  private func waitForStressBrowsers() -> Step {
    Step(
      name: "stress-browsers",
      timeout: 300,
      advance: {
        self.manager.liveSessions.count == self.workspace.allTabs.count
          && self.manager.liveSessions.allSatisfy { $0.hasBrowser }
      },
      finish: { completed in
        self.stressCreationCounts = Dictionary(
          uniqueKeysWithValues: self.manager.liveSessions.map { ($0.tabID, $0.browserCreationCount) })
        self.report(
          "every-stress-session-created-once",
          completed && self.stressCreationCounts.values.allSatisfy { $0 == 1 },
          "sessions=\(self.manager.liveSessions.count)")
      })
  }

  private func rapidlySwitchTabsAndSpaces() -> Step {
    Step(
      name: "rapid-switch",
      timeout: 30,
      begin: {
        for _ in 0..<12 {
          for spaceID in self.stressSpaceIDs {
            self.workspace.selectSpace(id: spaceID)
            for tab in self.workspace.tabs(in: spaceID) {
              self.workspace.selectTab(id: tab.id)
            }
          }
        }
        if let firstSpace = self.stressSpaceIDs.first,
          let firstTab = self.workspace.tabs(in: firstSpace).first
        {
          self.workspace.selectSpace(id: firstSpace)
          self.workspace.selectTab(id: firstTab.id)
        }
      },
      advance: {
        self.workspace.selectedSession?.isSurfaceVisible == true
          && self.manager.liveSessions.filter(\.isSurfaceVisible).count == 1
      },
      finish: { completed in
        let noDuplicateCreation = self.stressCreationCounts.allSatisfy { tabID, count in
          self.manager.session(for: tabID)?.browserCreationCount == count
        }
        self.report(
          "rapid-tab-space-switch-keeps-one-visible-surface",
          completed && noDuplicateCreation,
          "visible=\(self.manager.liveSessions.filter(\.isSurfaceVisible).count)")
      })
  }

  private func closeBackgroundTabsAndReopen() -> Step {
    Step(
      name: "close-reopen",
      timeout: 240,
      begin: {
        self.keptTabID = self.workspace.selectedTabID
        self.closeIDs = self.workspace.allTabs.map(\.id).filter { $0 != self.keptTabID }
        for tabID in self.closeIDs {
          self.workspace.closeTab(id: tabID)
        }
      },
      advance: {
        self.closeIDs.allSatisfy {
          self.workspace.tab(withID: $0) == nil && self.manager.session(for: $0) == nil
        }
      },
      finish: { completed in
        let reopened = self.workspace.reopenLastClosedTab()
        let reopenedReady = reopened.map { self.manager.session(for: $0) != nil } ?? false
        self.report(
          "background-close-removes-only-requested-tabs",
          completed,
          "closed=\(self.closeIDs.count) remaining=\(self.workspace.allTabs.count)")
        self.report(
          "recently-closed-tab-reopens-with-new-runtime",
          completed && reopened != nil && reopenedReady,
          "reopened=\(reopened != nil)")
      })
  }

  private func exercisePanelLifetime() -> Step {
    Step(
      name: "panel-lifetime",
      timeout: 30,
      begin: {
        let liveBefore = self.manager.liveSessionCount
        for _ in 0..<100 {
          self.runtime.showHistory()
          self.runtime.presentedInternalPanel = nil
          self.runtime.showDownloads()
          self.runtime.presentedInternalPanel = nil
        }
        self.runtime.record("m8:panels-iterated(100)")
        self.report(
          "history-download-panels-do-not-create-runtimes",
          self.manager.liveSessionCount == liveBefore,
          "live-before=\(liveBefore) live-after=\(self.manager.liveSessionCount)")
      },
      advance: { true },
      finish: { _ in })
  }

  private func createLazyGraph() -> Step {
    Step(
      name: "create-lazy-graph",
      timeout: 180,
      begin: {
        self.ensureSpaceCount(5)
        self.addTabsUntilEachSpaceHas(10, prefix: "lazy")
        self.workspace.flushSessionPersistence()
        print(
          "m8-self-test: lazy-seed domain-tabs=\(self.workspace.allTabs.count) spaces=\(self.workspace.spaces.count)")
      },
      advance: {
        self.workspace.spaces.count >= 5 && self.workspace.allTabs.count >= 50
      },
      finish: { completed in
        self.report(
          "lazy-seed-fifty-domain-tabs",
          completed,
          "tabs=\(self.workspace.allTabs.count) spaces=\(self.workspace.spaces.count)")
      })
  }

  private func persistLazyGraph() -> Step {
    Step(
      name: "persist-lazy-graph",
      timeout: 10,
      begin: {
        self.workspace.flushSessionPersistence()
      },
      advance: { true },
      finish: { completed in
        self.report(
          "lazy-seed-persisted",
          completed,
          "tabs=\(self.workspace.allTabs.count)")
      })
  }

  private func verifyLazyStartup() -> Step {
    Step(
      name: "verify-lazy-startup",
      timeout: 30,
      advance: {
        self.workspace.allTabs.count == 50 && self.manager.liveSessionCount == 1
      },
      finish: { completed in
        self.report(
          "lazy-restore-starts-with-one-live-session",
          completed,
          "domain-tabs=\(self.workspace.allTabs.count) live=\(self.manager.liveSessionCount)")
      })
  }

  private func activateLazySpaces() -> Step {
    Step(
      name: "activate-lazy-spaces",
      timeout: 30,
      begin: {
        for space in self.workspace.spaces {
          self.workspace.selectSpace(id: space.id)
          if let tabID = self.workspace.selectedTabID {
            self.activatedLazyTabIDs.append(tabID)
          }
        }
      },
      advance: {
        self.activatedLazyTabIDs.count == self.workspace.spaces.count
          && self.manager.liveSessionCount == self.workspace.spaces.count
      },
      finish: { completed in
        let inactiveTabsStayLazy = self.workspace.allTabs
          .map(\.id)
          .filter { !self.activatedLazyTabIDs.contains($0) }
          .allSatisfy { self.manager.session(for: $0) == nil }
        self.report(
          "lazy-restore-activates-only-selected-space-tabs",
          completed && inactiveTabsStayLazy,
          "activated=\(self.activatedLazyTabIDs.count) live=\(self.manager.liveSessionCount)")
      })
  }

  private func terminate() -> Step {
    Step(
      name: "terminate",
      timeout: 300,
      begin: {
        self.terminationFinished = false
        let runtime = self.runtime
        self.terminationCoordinator = ApplicationRuntime.Terminator(runtime: runtime) { [weak self] in
          self?.terminationFinished = true
        }
        self.terminationCoordinator?.start()
      },
      advance: { self.terminationFinished },
      finish: { completed in
        let clean = completed && self.manager.liveSessionCount == 0
          && self.runtime.hasShutDownCEF && self.runtime.cefShutdownCount == 1
        self.report(
          "all-live-sessions-close-before-single-cef-shutdown",
          clean,
          "live=\(self.manager.liveSessionCount) shutdowns=\(self.runtime.cefShutdownCount)")
        self.finishRun()
      })
  }

  private func ensureSpaceCount(_ count: Int) {
    while workspace.spaces.count < count {
      _ = workspace.createSpace(name: "M8 Space \(workspace.spaces.count + 1)")
    }
  }

  private func addTabsUntilEachSpaceHas(_ count: Int, prefix: String) {
    var index = 0
    for space in workspace.spaces {
      while workspace.tabs(in: space.id).count < count {
        let url = URL(string: "\(fixtureBaseURL)/page-a?m8-\(prefix)=\(index)")!
        _ = workspace.createTab(url: url, in: space.id, select: false)
        index += 1
      }
    }
  }

  private var fixtureBaseURL: URL {
    let prefix = "--m8-fixture-base-url="
    if let value = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
      let url = URL(string: String(value.dropFirst(prefix.count)))
    {
      return url
    }
    return workspace.homeURL
  }

  private func report(_ name: String, _ passed: Bool, _ detail: String) {
    checks += 1
    if !passed { failures += 1 }
    print("m8-self-test: \(passed ? "pass" : "FAIL") \(name) - \(detail)")
  }

  private func finishRun() {
    timer?.invalidate()
    timer = nil
    window?.close()
    print(
      "m8-self-test: checks=\(checks) failures=\(failures) spaces=\(workspace.spaces.count) tabs=\(workspace.allTabs.count) live=\(manager.liveSessionCount)")
    runtime.emitLifecycleTrace()
    exit(failures == 0 ? 0 : 2)
  }
}
