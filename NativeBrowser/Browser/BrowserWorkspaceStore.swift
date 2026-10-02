//
//  BrowserWorkspaceStore.swift
//  NativeBrowser
//
//  Application-facing workspace owner for Milestone 4.
//
//  WorkspaceCollection owns pure domain state. BrowserSessionManager owns only
//  runtime objects. This store is the seam between them: it performs one
//  coherent Space/tab selection transition, asks the runtime manager to create
//  or close sessions, and publishes the effective selected tab to the stable
//  browser surface host.
//

import AppKit
import Combine
import Foundation

@MainActor
final class BrowserWorkspaceStore: ObservableObject {
  let homeURL: URL
  let sessionManager: BrowserSessionManager
  let sessionStore: SessionStore

  private var workspace: WorkspaceCollection
  private var lastSavedSnapshot: WorkspaceSessionSnapshot?

  /// A shell-level command surface. Opening it does not create a tab.
  @Published private(set) var isSpotlightPresented = false

  /// Diagnostics and verification hooks. The store forwards runtime lifecycle
  /// events but remains the owner of all domain transitions.
  var onLifecycleEvent: ((String) -> Void)?

  init(initialTabURL: URL, sessionStore: SessionStore = SessionStore()) {
    homeURL = initialTabURL
    self.sessionStore = sessionStore
    let manager = BrowserSessionManager()
    sessionManager = manager

    let loadedSnapshot = sessionStore.loadSnapshot()
    if let loadedSnapshot, let restored = try? WorkspaceCollection(restoring: loadedSnapshot) {
      workspace = restored
      lastSavedSnapshot = loadedSnapshot
      AppLog.session.info(
        "workspace restored spaces=\(restored.spaces.count, privacy: .public) tabs=\(restored.allTabs.count, privacy: .public)")
    } else {
      let initialTab = BrowserTab(url: initialTabURL)
      workspace = WorkspaceCollection(initialTab: initialTab)
      lastSavedSnapshot = nil
    }

    manager.onLifecycleEvent = { [weak self] event in
      self?.onLifecycleEvent?(event)
    }
    manager.onRuntimeStateChanged = { [weak self] in
      self?.objectWillChange.send()
    }
    manager.onTabMetadataChanged = { [weak self] session in
      self?.refreshTabMetadata(from: session)
    }
    manager.onOpenNewTabRequest = { [weak self] session, url in
      self?.openPopupInNewTab(url: url, from: session)
    }
    manager.onCloseAccepted = { [weak self] session in
      self?.commitAcceptedClose(for: session.tabID)
    }
    manager.onCloseCancelled = { [weak self] session in
      guard let self else { return }
      self.emit("tab:close-cancelled")
      AppLog.session.info(
        "tab close cancelled id=\(session.tabID.uuidString, privacy: .public)")
    }
    manager.onSessionDidClose = { [weak self] session in
      guard let self else { return }
      self.reconcileUnexpectedClose(for: session.tabID)
      self.activateSelectedTabRuntimeIfNeeded()
    }

    // Restore both panes of the selected group. Other groups remain lazy until
    // selected, keeping startup cost proportional to the visible presentation.
    ensureSelectedPresentationSessions()
    publishWorkspace()
  }

  // MARK: - Domain projections

  /// Read-only projections. `workspace` remains the only mutable domain source
  /// of truth; these are never independently mutated by UI code.
  var spaces: [BrowserSpace] { workspace.spaces }
  var selectedSpaceID: UUID { workspace.selectedSpaceID }
  var selectedSpace: BrowserSpace? { workspace.selectedSpace }
  var selectedTabID: UUID? { workspace.selectedTabID }
  var selectedTab: BrowserTab? { workspace.selectedTab }
  var tabs: [BrowserTab] { workspace.currentTabs }
  var globalPinnedTabs: [BrowserTab] { workspace.globalPinnedTabs }
  var spacePinnedTabs: [BrowserTab] { workspace.currentSpacePinnedTabs }
  var temporaryTabs: [BrowserTab] { workspace.currentTemporaryTabs }
  var currentTabIDs: [UUID] { workspace.currentTabIDs }
  var allTabs: [BrowserTab] { workspace.allTabs }
  var allTabIDs: [UUID] { workspace.allTabIDs }
  var recentlyClosed: [ClosedTabSnapshot] { workspace.recentlyClosed }
  var canReopenClosedTab: Bool { workspace.canReopenClosedTab }

  func tabs(in spaceID: UUID) -> [BrowserTab] {
    workspace.tabs(in: spaceID)
  }

  func space(withID id: UUID) -> BrowserSpace? {
    workspace.space(withID: id)
  }

  var selectedSession: BrowserSession? {
    selectedTabID.flatMap { sessionManager.session(for: $0) }
  }

  var liveSessionCount: Int { sessionManager.liveSessionCount }
  var liveSessions: [BrowserSession] { sessionManager.liveSessions }
  var hasLiveSessions: Bool { sessionManager.hasLiveSessions }
  var isTerminating: Bool { sessionManager.isTerminating }

  func tab(withID id: UUID) -> BrowserTab? {
    workspace.tab(withID: id)
  }

  func space(forTabID tabID: UUID) -> BrowserSpace? {
    guard let spaceID = workspace.spaceID(containing: tabID) else { return nil }
    return workspace.space(withID: spaceID)
  }

  func spaceID(forTabID tabID: UUID) -> UUID? {
    workspace.spaceID(containing: tabID)
  }

  func session(for tabID: UUID) -> BrowserSession? {
    sessionManager.session(for: tabID)
  }

  /// The durable projection used by persistence and the process-level restore
  /// verifier. It deliberately cannot contain runtime-only state.
  var sessionSnapshot: WorkspaceSessionSnapshot {
    WorkspaceSessionSnapshot(workspace: workspace)
  }

  /// Synchronously flushes the current durable domain state. This is called
  /// before application shutdown starts closing Chromium, and again is safe to
  /// call when no live sessions exist.
  func flushSessionPersistence() {
    persistIfNeeded()
  }

  /// A pair stays grouped in the domain even when another tab is selected.
  var activeSplit: BrowserSplitLayout? { workspace.activeSplit }

  func splitGroup(containing tabID: UUID) -> BrowserSplitLayout? {
    workspace.splitGroup(containing: tabID)
  }

  func canSplit(with tabID: UUID) -> Bool {
    guard !isTerminating, !isSpotlightPresented, let selectedTabID,
          workspace.canSplit(with: tabID),
          !sessionManager.isClosing(tabID: tabID),
          !sessionManager.isClosing(tabID: selectedTabID) else { return false }
    return activeSplit?.contains(tabID) != true
  }

  @discardableResult
  func splitTab(_ tabID: UUID, on side: BrowserSplitLayout.Side) -> Bool {
    guard canSplit(with: tabID) else { return false }
    var committed = false
    withSelectionTransition {
      committed = workspace.createSplit(with: tabID, on: side)
      if committed { ensureSelectedPresentationSessions() }
    }
    if committed {
      selectedSession?.focusPage()
      emit("split:committed")
    }
    return committed
  }

  func setSplitFraction(_ fraction: CGFloat) {
    let before = sessionSnapshot
    guard workspace.setSplitFraction(fraction) else { return }
    persistIfNeeded(comparedTo: before)
    publishWorkspace()
  }

  func endSplit(keeping tabID: UUID) {
    withSelectionTransition {
      guard workspace.endSplit(keeping: tabID) else { return }
      _ = workspace.selectTab(id: tabID)
      ensureSelectedPresentationSessions()
    }
    selectedSession?.focusPage()
  }

  func swapSplitSides(containing tabID: UUID) {
    let before = sessionSnapshot
    guard workspace.swapSplitSides(containing: tabID) else { return }
    persistIfNeeded(comparedTo: before)
    publishWorkspace()
  }

  func ungroupSplit(containing tabID: UUID) {
    withSelectionTransition {
      guard workspace.ungroupSplit(containing: tabID) else { return }
      ensureSelectedPresentationSessions()
    }
    selectedSession?.focusPage()
  }

  @discardableResult
  func moveSplitGroup(containing tabID: UUID, to tier: WorkspaceCollection.TabTier,
                      before targetID: UUID? = nil) -> Bool {
    guard !isTerminating else { return false }
    var moved = false
    withSelectionTransition {
      moved = workspace.moveSplitGroup(containing: tabID, to: tier, before: targetID)
      guard moved else { return }
      ensureSelectedPresentationSessions()
    }
    return moved
  }

  // MARK: - Space lifecycle

  /// Creates and selects a Space with one fresh tab and one fresh runtime.
  @discardableResult
  func createSpace(name: String? = nil) -> UUID? {
    guard !isTerminating else { return nil }

    let tab = BrowserTab(url: homeURL)
    var createdSpaceID: UUID?
    withSelectionTransition {
      createdSpaceID = workspace.createSpace(initialTab: tab, name: name, select: true)
      guard createdSpaceID != nil else { return }
      _ = sessionManager.createSession(for: tab.id, initialURL: homeURL)
    }

    guard let createdSpaceID else { return nil }
    let name = workspace.space(withID: createdSpaceID)?.name ?? "Space"
    AppLog.session.info(
      "space created id=\(createdSpaceID.uuidString, privacy: .public) name=\(name, privacy: .public)"
    )
    emit("space:created(\(createdSpaceID.uuidString))")
    logTabCreated(tab.id, url: homeURL)
    return createdSpaceID
  }

  @discardableResult
  func renameSpace(id: UUID, name: String) -> Bool {
    let changed = workspace.renameSpace(id: id, name: name)
    if changed {
      publishWorkspace()
      persistIfNeeded()
      emit("space:renamed(\(id.uuidString))")
    }
    return changed
  }

  /// Keep Spotlight open while changing Space so submission targets the new Space.
  func selectSpace(id: UUID) {
    guard workspace.space(withID: id) != nil,
      workspace.selectedSpaceID != id
    else { return }
    withSelectionTransition(preserveSpotlight: true) {
      workspace.selectSpace(id: id)
      ensureSelectedPresentationSessions()
    }
    emit("space:selected(\(id.uuidString))")
  }

  // MARK: - Tab lifecycle

  /// Creates a tab at the front of the currently selected Space.
  @discardableResult
  func createTab(url: URL? = nil, select: Bool = true, title: String = "") -> UUID? {
    createTab(url: url, in: workspace.selectedSpaceID, select: select, title: title)
  }

  /// Creates a tab at the front of an explicit Space, or immediately after
  /// `sourceTabID` when that tab belongs to the Space. A background-space
  /// popup uses `select: false`, so it cannot switch Spaces or take keyboard focus.
  @discardableResult
  func createTab(
    url: URL?, in spaceID: UUID, select: Bool, title: String = "", after sourceTabID: UUID? = nil
  ) -> UUID? {
    guard !isTerminating,
      workspace.space(withID: spaceID) != nil,
      !select || workspace.selectedSpaceID == spaceID
    else { return nil }

    let insertionIndex = workspace.newTabInsertionIndex(in: spaceID, after: sourceTabID)
    let tab = BrowserTab(title: title, url: url)
    let initialURL = url ?? homeURL
    var inserted = false
    withSelectionTransition {
      inserted = workspace.insertTab(tab, in: spaceID, at: insertionIndex, select: select)
      guard inserted else { return }
      _ = sessionManager.createSession(
        for: tab.id,
        initialURL: initialURL,
        initialTitle: title)
    }
    guard inserted else { return nil }
    logTabCreated(tab.id, url: initialURL)
    return tab.id
  }

  func presentSpotlight() {
    guard !isTerminating else { return }
    selectedSession?.blur()
    isSpotlightPresented = true
  }

  func dismissSpotlight(focusPage: Bool = true) {
    guard isSpotlightPresented else { return }
    isSpotlightPresented = false
    if focusPage { selectedSession?.focusPage() }
  }

  func submitSpotlight(opening url: URL) {
    guard isSpotlightPresented else { return }
    isSpotlightPresented = false
    guard createTab(url: url) != nil else { return }
    selectedSession?.focusPage()
  }

  func selectTab(id: UUID, focusingPage: Bool = false) {
    if workspace.selectedTabID == id, isSpotlightPresented {
      dismissSpotlight()
      return
    }
    if workspace.selectedTabID == id, focusingPage {
      selectedSession?.focusPage()
      return
    }
    guard (workspace.globalPinnedTabIDs.contains(id)
      || workspace.spaceID(containing: id) == workspace.selectedSpaceID),
      workspace.selectedTabID != id
    else { return }

    let wasSpotlightPresented = isSpotlightPresented
    withSelectionTransition(pageHeldKeyboardOverride: focusingPage ? true : nil) {
      workspace.selectTab(id: id)
      ensureSelectedPresentationSessions()
    }
    if wasSpotlightPresented { selectedSession?.focusPage() }
    emit("tab:selected")
    AppLog.session.info("tab selected id=\(id.uuidString, privacy: .public)")
  }

  @discardableResult
  func moveTab(_ id: UUID, to tier: WorkspaceCollection.TabTier, before targetID: UUID? = nil) -> Bool {
    guard !isTerminating else { return false }
    var moved = false
    withSelectionTransition {
      moved = workspace.moveTab(id, to: tier, before: targetID)
      if moved { ensureSelectedPresentationSessions() }
    }
    return moved
  }

  @discardableResult
  func selectTab(at index: Int) -> Bool {
    guard currentTabIDs.indices.contains(index) else { return false }
    let id = currentTabIDs[index]
    selectTab(id: id)
    return selectedTabID == id
  }

  @discardableResult
  func selectLastTab() -> Bool {
    guard let id = currentTabIDs.last else { return false }
    selectTab(id: id)
    return selectedTabID == id
  }

  /// Requests a runtime close. The domain tab remains visible until CEF
  /// accepts the request, because a beforeunload dialog may cancel it.
  func closeTab(id: UUID) {
    guard !isTerminating, workspace.tab(withID: id) != nil,
      !sessionManager.isClosing(tabID: id)
    else { return }

    guard sessionManager.session(for: id) != nil else {
      // Lazy-restored tabs have no renderer and therefore no beforeunload path.
      commitTabClose(id: id, reason: .userClosed)
      return
    }

    sessionManager.requestClose(tabID: id)
    AppLog.session.info(
      "tab close requested id=\(id.uuidString, privacy: .public) live=\(self.sessionManager.liveSessionCount, privacy: .public)"
    )
    emit("tab:close-requested")
  }

  func closeSelectedTab() {
    guard let id = selectedTabID else { return }
    closeTab(id: id)
  }

  /// Clears the temporary tier in one Space while preserving the visible tab
  /// or both members of the active group. Each tab uses the normal close path, so a
  /// page can still cancel its own beforeunload request.
  func clearTemporaryTabs(in spaceID: UUID) {
    guard !isTerminating, workspace.space(withID: spaceID) != nil else { return }
    let protectedIDs = Set(activeSplit?.tabIDs ?? selectedTabID.map { [$0] } ?? [])
    let ids = workspace.tabIDs(in: .temporary(spaceID))
    for id in ids where !protectedIDs.contains(id) {
      closeTab(id: id)
    }
  }

  /// Reopens the newest user-closed snapshot in its original Space and index.
  /// The tab and runtime identities are always new.
  @discardableResult
  func reopenLastClosedTab() -> UUID? {
    guard !isTerminating, let snapshot = workspace.popRecentlyClosed() else { return nil }
    let tab = BrowserTab(title: snapshot.title, url: snapshot.url)
    var restored = false
    withSelectionTransition {
      restored = workspace.restoreTab(tab, from: snapshot)
      guard restored else { return }
      _ = sessionManager.createSession(
        for: tab.id,
        initialURL: snapshot.url ?? homeURL,
        initialTitle: snapshot.title)
    }
    guard restored else { return nil }

    emit("tab:reopened(\(tab.id.uuidString))")
    AppLog.session.info(
      "reopened a closed tab id=\(tab.id.uuidString, privacy: .public) space=\(snapshot.spaceID.uuidString, privacy: .public) url=\(URLLogSanitizer.sanitized(snapshot.url), privacy: .public)"
    )
    return tab.id
  }

  // MARK: - Runtime and navigation forwarding

  func attachSurfaceHost(_ host: BrowserSurfaceHostView) {
    sessionManager.attachSurfaceHost(host)
    sessionManager.setSurfacePresentation(selectedTabID: selectedTabID, split: activeSplit)
  }

  func requestCloseAllForTermination() {
    sessionManager.requestCloseAllForTermination()
  }

  func releaseBrowserViews() {
    sessionManager.releaseBrowserViews()
  }

  @discardableResult
  func loadInSelectedTab(_ url: URL) -> Bool {
    guard let selectedSession else { return false }
    selectedSession.load(url)
    return true
  }

  // MARK: - Selection transition

  /// The one workspace-level focus transition for tab selection, new tabs,
  /// reopening, closing and Space switching.
  @discardableResult
  private func withSelectionTransition<T>(_ change: () -> T) -> T {
    withSelectionTransition(pageHeldKeyboardOverride: nil, preserveSpotlight: false, change)
  }

  private func withSelectionTransition<T>(
    pageHeldKeyboardOverride: Bool? = nil,
    preserveSpotlight: Bool = false,
    _ change: () -> T
  ) -> T {
    let outgoing = selectedSession
    let previousSelection = workspace.selectedTabID
    let previousSpace = workspace.selectedSpaceID
    // A tab owns the keyboard through either Chromium or its native address
    // editor. Capture that before publishing selection: hiding its stable
    // toolbar ends editing, so a later UI observer cannot recover this intent.
    let pageHeldKeyboard = pageHeldKeyboardOverride
      ?? (outgoing?.ownsPageKeyboard == true || outgoing?.isEditingAddressField == true)
    let beforeSnapshot = sessionSnapshot

    let result = change()
    persistIfNeeded(comparedTo: beforeSnapshot)

    if isSpotlightPresented, !preserveSpotlight,
       (workspace.selectedTabID != previousSelection || workspace.selectedSpaceID != previousSpace) {
      isSpotlightPresented = false
    }

    guard workspace.selectedTabID != previousSelection else {
      publishWorkspace()
      return result
    }

    outgoing?.blur()
    if !pageHeldKeyboard {
      // Set the intent before the incoming surface is made visible. This closes
      // the async browser-creation race where OnAfterCreated arrives late.
      selectedSession?.blur()
    }
    publishWorkspace()

    if let incoming = selectedSession, incoming !== outgoing {
      if pageHeldKeyboard {
        incoming.focusPage()
      } else {
        incoming.blur()
      }
    }
    return result
  }

  // MARK: - Domain/runtime callbacks

  private func commitAcceptedClose(for tabID: UUID) {
    guard !isTerminating else { return }
    commitTabClose(id: tabID, reason: .userClosed)
  }

  private func reconcileUnexpectedClose(for tabID: UUID) {
    guard !isTerminating, workspace.tab(withID: tabID) != nil,
      !sessionManager.isClosePending(tabID: tabID)
    else { return }
    AppLog.session.warning(
      "runtime closed before a workspace close request; reconciling tab id=\(tabID.uuidString, privacy: .public)")
    commitTabClose(id: tabID, reason: .userClosed)
  }

  /// Completes the last-tab replacement after the old runtime has reached
  /// OnBeforeClose. This is intentionally event-driven; no timer or guessed
  /// delay is used to coordinate two Chromium browser lifetimes.
  private func activateSelectedTabRuntimeIfNeeded() {
    guard !isTerminating, selectedTab != nil, selectedSession == nil else { return }
    ensureSelectedPresentationSessions()
    publishWorkspace()
  }

  /// Commits the pure-domain removal after CEF acceptance, or immediately for a
  /// lazy tab that has no live browser. Runtime ownership remains in the
  /// manager until OnBeforeClose; this method never releases it early.
  private func commitTabClose(id: UUID, reason: WorkspaceTabCloseReason) {
    guard workspace.tab(withID: id) != nil else { return }

    let selectedCloseHeldPageKeyboard = workspace.selectedTabID == id
      ? sessionManager.session(for: id)?.ownsPageKeyboard == true
      : false
    if workspace.selectedTabID == id {
      // A selected close can race with the native address field's shared field
      // editor. Clear it before the tab leaves the domain so the replacement
      // tab never inherits an orphaned editing session.
      sessionManager.session(for: id)?.releaseFocusBeforeTabRemoval()
    }

    let closingSplit = activeSplit.flatMap { $0.contains(id) ? $0 : nil }

    var result: WorkspaceTabCloseResult?
    withSelectionTransition(
      pageHeldKeyboardOverride: selectedCloseHeldPageKeyboard ? true : nil
    ) {
      if let split = closingSplit {
        _ = workspace.endSplit(keeping: id)
        workspace.selectTab(id: split.leftTabID == id ? split.rightTabID : split.leftTabID)
      }
      let closeResult = workspace.close(id, reason: reason)
      guard closeResult.outcome != .unknownTab, let spaceID = closeResult.spaceID else {
        result = closeResult
        return
      }
      result = closeResult
      if closeResult.needsReplacementTab {
        let replacement = BrowserTab()
        let inserted = workspace.appendTab(replacement, in: spaceID, select: false)
        if inserted {
          // The active Space keeps its existing invariant: a last-tab close
          // immediately has a visible replacement. An inactive Space may
          // leave that replacement domain-only until the Space is selected.
          if workspace.selectedSpaceID == spaceID,
            !sessionManager.isClosing(tabID: id)
          {
            _ = sessionManager.createSession(for: replacement.id, initialURL: homeURL)
          }
          logTabCreated(replacement.id, url: homeURL)
        }
      }

      if workspace.selectedTab != nil,
        !sessionManager.isClosing(tabID: id)
      {
        // When the selected tab was the Space's last tab, its replacement is
        // created in the domain immediately but its Chromium runtime waits for
        // the closing session's OnBeforeClose. Creating a new CEF view from
        // inside the old DoClose callback can re-enter the view hierarchy and
        // strand the closing browser.
        ensureSelectedPresentationSessions()
      }
    }

    guard let result, result.outcome != .unknownTab else { return }
    AppLog.session.info(
      "tab closed id=\(id.uuidString, privacy: .public) live=\(self.sessionManager.liveSessionCount, privacy: .public)"
    )
    emit("tab:closed")
  }

  private func refreshTabMetadata(from session: BrowserSession) {
    guard var tab = workspace.tab(withID: session.tabID) else { return }
    let beforeSnapshot = sessionSnapshot
    if !session.title.isEmpty { tab.title = session.title }
    if session.url != nil { tab.url = session.url }
    tab.isLoading = session.isLoading
    guard workspace.refresh(tab) else { return }
    // Loading state is intentionally part of the live BrowserTab projection so
    // the sidebar can render progress, but it is absent from the snapshot. A
    // URL/title callback therefore persists; a transient loading callback does
    // not create a write storm.
    persistIfNeeded(comparedTo: beforeSnapshot)
    objectWillChange.send()
  }

  /// Popup routing always begins with the source runtime identity. The source
  /// tab's Space, not the currently selected Space, determines ownership.
  private func openPopupInNewTab(url: String, from session: BrowserSession) {
    guard !isTerminating, !url.isEmpty, let target = URL(string: url),
      let sourceSpaceID = workspace.globalPinnedTabIDs.contains(session.tabID)
        ? workspace.selectedSpaceID : workspace.spaceID(containing: session.tabID)
    else { return }

    let shouldSelect = workspace.selectedTabID == session.tabID
    let loggedURL = URLLogSanitizer.sanitized(target)
    AppLog.session.info(
      "popup routed to source Space=\(sourceSpaceID.uuidString, privacy: .public) url=\(loggedURL, privacy: .public)"
    )
    emit("popup:new-tab(\(loggedURL))")
    _ = createTab(url: target, in: sourceSpaceID, select: shouldSelect, after: session.tabID)
  }

  private func publishWorkspace() {
    objectWillChange.send()
    sessionManager.setSurfacePresentation(selectedTabID: workspace.selectedTabID, split: activeSplit)
  }

  private func ensureSelectedPresentationSessions() {
    guard !isTerminating, let selectedTab = workspace.selectedTab else { return }
    _ = ensureSession(for: selectedTab)
    if let group = activeSplit {
      for id in group.tabIDs where id != selectedTab.id && !sessionManager.isClosing(tabID: id) {
        if let tab = workspace.tab(withID: id) { _ = ensureSession(for: tab) }
      }
    }
  }

  /// Ensures exactly one runtime for a selected domain tab. This is the only
  /// path used by lazy restore activation; no placeholder BrowserSession is
  /// created for an unselected restored tab.
  @discardableResult
  private func ensureSession(for tab: BrowserTab) -> BrowserSession? {
    if let existing = sessionManager.session(for: tab.id) {
      return existing
    }
    return sessionManager.createSession(
      for: tab.id,
      initialURL: tab.url ?? homeURL,
      initialTitle: tab.title)
  }

  /// Saves only when the durable projection changed since the last successful
  /// write. The synchronous save is small and is also repeated at termination
  /// so the final committed URL/title cannot be lost behind a CEF callback.
  private func persistIfNeeded(comparedTo previous: WorkspaceSessionSnapshot? = nil) {
    let current = sessionSnapshot
    if let previous, previous == current {
      return
    }
    guard sessionStore.isEnabled, current != lastSavedSnapshot else { return }
    if sessionStore.saveSnapshot(current) {
      lastSavedSnapshot = current
    }
  }

  private func logTabCreated(_ tabID: UUID, url: URL) {
    emit("tab:created(\(tabID.uuidString))")
    AppLog.session.info(
      "tab created id=\(tabID.uuidString, privacy: .public) url=\(URLLogSanitizer.sanitized(url), privacy: .public)"
    )
  }

  private func emit(_ event: String) {
    onLifecycleEvent?(event)
  }
}
