import AppKit
import Combine
import CioModel
import CioEngine
import CioUI

/// Scoped key handling exists only while Control's switcher flight is open.
/// The frozen candidate set is committed once, on release, Return, or click.
@MainActor
final class RecentTabSwitcherCoordinator {
  private let workspace: BrowserWorkspaceStore
  private var selection: RecentTabSelection?
  private var originID: UUID?
  private var originSpaceID: UUID?
  private weak var parent: NSWindow?
  private var eventMonitor: Any?
  private lazy var arrowKeys = RecentTabSwitcherArrowKeys(
    isEligible: { [weak self] in
      guard let self else { return false }
      return self.selection != nil && NSApp.isActive && self.parent?.isKeyWindow == true
    },
    onAdvance: { [weak self] forward in self?.advance(forward: forward) })
  private lazy var input = RecentTabSwitcherInputSession(
    onReveal: { [weak self] in self?.showPanel() },
    onCommit: { [weak self] in self?.finish(commit: true) })
  private var observations = Set<AnyCancellable>()
  private var workspaceObservation: AnyCancellable?
  private lazy var panel = RecentTabSwitcherPanel { [weak self] id in
    self?.selection?.select(id)
    self?.finish(commit: true)
  }

  init(workspace: BrowserWorkspaceStore) {
    self.workspace = workspace
    workspaceObservation = workspace.objectWillChange.merge(with: workspace.pagePreviews.imagesDidChange).sink { [weak self] in
      DispatchQueue.main.async { self?.reconcile() }
    }
  }

  func advance(forward: Bool) {
    if selection != nil {
      selection?.advance(forward: forward)
      refreshPanel()
      return
    }
    guard workspace.canCycleTabs, let window = NSApp.keyWindow ?? NSApp.mainWindow,
          window.attachedSheet == nil else { return }
    let candidates = workspace.recentTabCandidates
    let state = RecentTabSelection(candidateIDs: candidates.map(\.id),
                                   currentID: workspace.selectedTabID, forward: forward)
    // A menu click opens the same chooser, latched until Return/click/Escape.
    // Keyboard invocation instead commits on the initiating Control release.
    let controlDown = NSApp.currentEvent?.modifierFlags.contains(.control) == true
      || NSEvent.modifierFlags.contains(.control)
    originID = workspace.selectedTabID
    originSpaceID = workspace.selectedSpaceID
    parent = window
    selection = state
    workspace.dismissSpotlight(focusPage: false)
    installInput(in: window)
    input.begin(controlDown: controlDown)
  }

  private func showPanel() {
    guard input.isVisible, let parent, selection != nil else { return }
    refreshPanel()
    panel.present(in: parent)
    let ids = workspace.selectedTabID.map { workspace.splitGroup(containing: $0)?.tabIDs ?? [$0] } ?? []
    for id in ids {
      if let session = workspace.sessionManager.session(for: id) {
        workspace.pagePreviews.capture(session) { [weak self] _ in self?.refreshPanel() }
      }
    }
  }

  private func installInput(in window: NSWindow) {
    arrowKeys.begin()
    // Chromium can receive raw key events through its own pump rather than
    // NSApplication's local monitor. Acknowledge only while this flight owns
    // input, through the same handler used by native controls and editors.
    NotificationCenter.default.publisher(for: Notification.Name("CioRecentTabSwitcherArrow"))
      .sink { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self, let request = notification.object as? NSMutableDictionary,
                let event = request["event"] as? NSEvent else { return }
          if self.handle(event) == nil { request["handled"] = true }
        }
      }.store(in: &observations)
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
      let consumed = MainActor.assumeIsolated {
        guard let self else { return false }
        return self.handle(event) == nil
      }
      return consumed ? nil : event
    }
    for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
        MainActor.assumeIsolated { self?.finish(commit: false) }
      }.store(in: &observations)
    }
    NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.finish(commit: false) }
    }.store(in: &observations)
    NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: window).sink { [weak self] _ in
      MainActor.assumeIsolated {
        if let self, self.input.isVisible, let parent = self.parent { self.panel.layout(in: parent) }
      }
    }.store(in: &observations)
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard selection != nil else { return event }
    if event.type == .flagsChanged {
      input.controlChanged(isDown: event.modifierFlags.contains(.control))
      return event
    }
    if event.type == .leftMouseDown {
      if !input.isVisible || event.window !== panel.window { finish(commit: false) }
      return event
    }
    let eventWindow = event.window ?? NSApp.keyWindow
    guard eventWindow === parent || (input.isVisible && eventWindow === panel.window) else {
      finish(commit: false); return event
    }
    switch event.keyCode {
    case 53: finish(commit: false); return nil
    case 36, 76: finish(commit: true); return nil
    case 48:
      guard event.modifierFlags.contains(.control),
            event.modifierFlags.intersection([.command, .option]).isEmpty else {
        finish(commit: false); return event
      }
      advance(forward: !event.modifierFlags.contains(.shift)); return nil
    case 123, 124:
      guard event.modifierFlags.intersection([.command, .option]).isEmpty else {
        finish(commit: false); return event
      }
      advance(forward: event.keyCode == 124); return nil
    default: finish(commit: false); return event
    }
  }

  private func reconcile() {
    guard selection != nil else { return }
    guard workspace.selectedTabID == originID, workspace.selectedSpaceID == originSpaceID,
          !workspace.isTerminating, parent?.attachedSheet == nil else { finish(commit: false); return }
    let available = Set(workspace.allTabs.filter {
      !$0.isSpacePinClosed && !workspace.sessionManager.isClosing(tabID: $0.id)
    }.map(\.id))
    selection?.retainAvailable(available)
    if selection?.candidateIDs.isEmpty == true { finish(commit: false) }
    else { refreshPanel() }
  }

  private func refreshPanel() {
    guard input.isVisible, let selection else { return }
    let candidates = selection.candidateIDs.compactMap { id -> RecentTabCandidate? in
      guard workspace.tab(withID: id) != nil else { return nil }
      let ids = workspace.splitGroup(containing: id)?.tabIDs ?? [id]
      let pages = ids.compactMap { pageID -> RecentTabPage? in
        guard let page = workspace.tab(withID: pageID), !page.isSpacePinClosed,
              !workspace.sessionManager.isClosing(tabID: pageID) else { return nil }
        return RecentTabPage(id: pageID, title: page.displayTitle, host: page.url?.host ?? "",
          favicon: page.faviconData.flatMap { BrowserArtwork.decode($0, as: .favicon) }
            .map { NSImage(cgImage: $0, size: .zero) },
          preview: workspace.pagePreviews.image(for: pageID, url: page.url))
      }
      return RecentTabCandidate(id: id, pages: pages)
    }
    panel.update(candidates: candidates, selectedID: selection.selectedID)
  }

  private func finish(commit: Bool) {
    guard let selection else { return }
    let wasVisible = input.isVisible
    arrowKeys.end()
    input.end()
    self.selection = nil
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    observations.removeAll()
    parent = nil
    if wasVisible { panel.dismiss() }
    if commit, let id = selection.selectedID { workspace.activateRecentTab(id) }
  }
}
