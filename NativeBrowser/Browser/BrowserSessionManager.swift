//
//  BrowserSessionManager.swift
//  NativeBrowser
//
//  The application-level owner of the tab workspace (Milestone 3 sections 2, 5,
//  6, 8, 10 and 25).
//
//  It owns, and is the only owner of:
//
//    * the ordered visible tabs and the selected tab  (a pure TabCollection)
//    * exactly one BrowserSession per tab identifier
//    * the sessions that are closing but have not reached OnBeforeClose yet
//    * the in-memory recently-closed stack used by Cmd-Shift-T
//    * one ChromiumContainerView per live session
//
//  There is deliberately no "current CefBrowser" and no second liveness
//  registry: ApplicationRuntime asks this object whether a browser is still
//  alive, and the typed onLiveSessionDidClose hook is what termination waits on.
//  Nothing infers closure from a lifecycle string.
//
//  Closing a tab and destroying its Chromium runtime are two different instants
//  (section 6). The tab leaves the visible order immediately; the BrowserSession
//  stays in `sessions` until CEF reports OnBeforeClose.
//

import AppKit
import Foundation

@MainActor
final class BrowserSessionManager: ObservableObject {
  /// URL a new tab opens when the caller does not supply one.
  let newTabURL: URL

  // MARK: - Published state

  /// Ordered visible tabs.
  @Published private(set) var tabs: [BrowserTab] = []
  @Published private(set) var selectedTabID: UUID?
  @Published private(set) var recentlyClosed: [ClosedTabSnapshot] = []
  /// How many Chromium runtimes this manager still owns. Includes sessions that
  /// are closing but have not reached OnBeforeClose yet, because those still
  /// count as live for termination (section 8).
  @Published private(set) var liveSessionCount = 0

  // MARK: - Hooks

  /// Lifecycle milestones for logging and the verification tooling. Diagnostics
  /// only: no control flow depends on the strings.
  var onLifecycleEvent: ((String) -> Void)?

  /// Typed notification that one session reached OnBeforeClose and was released.
  /// Carries the session, so the receiver knows *which* browser closed.
  var onLiveSessionDidClose: ((BrowserSession) -> Void)?

  /// Called just before published state changes. ApplicationRuntime mirrors it
  /// so the SwiftUI scene - and the menu commands built from it - re-evaluate
  /// when the tab list or the selection changes.
  var onWillPublish: (() -> Void)?

  // MARK: - Runtime registry

  private var collection: TabCollection
  private var sessions: [UUID: BrowserSession] = [:]
  /// Order in which closing sessions were requested, so the closing set is
  /// deterministic (dictionary order is not).
  private var closingTabIDs: [UUID] = []
  private var containers: [UUID: ChromiumContainerView] = [:]
  private weak var surfaceHost: BrowserSurfaceHostView?

  private(set) var isTerminating = false

  // MARK: - Init

  init(initialTabURL: URL) {
    newTabURL = initialTabURL
    let initialTab = BrowserTab(url: initialTabURL)
    collection = TabCollection.workspace(initialTab: initialTab)
    // The session exists before the first publication, so the first state an
    // observer sees already owns its runtime. The surface follows when the
    // window attaches its host.
    registerSession(for: initialTab.id, initialURL: initialTabURL)
    publishState()
  }

  // MARK: - Queries

  var selectedSession: BrowserSession? {
    selectedTabID.flatMap { sessions[$0] }
  }

  func session(for tabID: UUID) -> BrowserSession? {
    sessions[tabID]
  }

  var hasLiveSessions: Bool { !sessions.isEmpty }

  /// Every live Chromium runtime, visible tabs first and then the ones that are
  /// closing. This is the one registry termination consults.
  var liveSessions: [BrowserSession] {
    liveSessionOrder.compactMap { sessions[$0] }
  }

  /// Visible tabs in sidebar order, followed by the closing sessions in the
  /// order their close was requested.
  ///
  /// Deduplicated: while the whole application is terminating, a tab is still in
  /// the visible order *and* marked as closing, and it must be counted once.
  var liveSessionOrder: [UUID] {
    var seen = Set<UUID>()
    var order: [UUID] = []
    for tabID in collection.tabIDs + closingTabIDs
    where sessions[tabID] != nil && seen.insert(tabID).inserted {
      order.append(tabID)
    }
    return order
  }

  func isClosing(tabID: UUID) -> Bool {
    closingTabIDs.contains(tabID)
  }

  var canReopenClosedTab: Bool { collection.canReopenClosedTab }

  /// The CEF browser identifier of every live session (nil while a browser has
  /// not been created yet). Used by the multi-tab integration test to prove that
  /// each tab owns a distinct Chromium browser.
  var liveBrowserIdentifiers: [Int] {
    liveSessions.compactMap { $0.browserIdentifier }
  }

  // MARK: - Selection transition

  /// Runs one change to the tab order as a single selection transition.
  ///
  /// Every path that can move the selection goes through here - selecting a tab,
  /// creating one, reopening one, closing one, and the replacement tab a
  /// last-tab close creates - so the keyboard rules exist once instead of being
  /// restated by each caller:
  ///
  ///   1. capture whether the outgoing *page* owned the keyboard (AppKit's first
  ///      responder, or a hand-over to it that is still in flight)
  ///   2. run `change`, which mutates the collection (and therefore the
  ///      selection) and registers sessions, but never touches a view
  ///   3. if the selection did not move, stop: a background insert or a
  ///      background close leaves the active tab and the keyboard alone
  ///   4. release the outgoing page's CEF and AppKit focus, while its surface is
  ///      still visible
  ///   5. publish state and sync the surface, which hides the old container and
  ///      shows the new one
  ///   6. hand the keyboard to the newly selected session only when the page had
  ///      it before; when the native address field had it, the new session is
  ///      explicitly told not to take it, so the Chromium browser it is still
  ///      creating cannot steal it later
  ///
  /// Nothing here waits, polls or times out: the asynchronous half - a browser
  /// arriving after its tab was hidden - is answered by
  /// BrowserSession.wantsPageFocus, which step 6 sets.
  @discardableResult
  private func withSelectionTransition<T>(_ change: () -> T) -> T {
    let outgoing = selectedSession
    let previousSelection = collection.selectedTabID
    let pageHeldKeyboard = outgoing?.ownsPageKeyboard ?? false

    let result = change()

    guard collection.selectedTabID != previousSelection else {
      // The tab order changed but the selection did not: publish it, and leave
      // the keyboard with whoever owns it.
      publishState()
      return result
    }

    outgoing?.blur()
    publishState()

    if let incoming = selectedSession, incoming !== outgoing {
      if pageHeldKeyboard {
        incoming.focusPage()
      } else {
        incoming.blur()
      }
    }
    return result
  }

  /// Adds one tab and its session to the two registries - and nothing else.
  ///
  /// Publication, surface work and focus belong to the caller's selection
  /// transition: the container has to become visible (step 5 there) before a
  /// browser is allowed to be created in it, because that is what decides
  /// whether the new browser may take the keyboard.
  @discardableResult
  private func insertTab(_ tab: BrowserTab, at index: Int, select: Bool, initialURL: URL) -> UUID {
    collection.insert(tab, at: index, select: select)
    registerSession(for: tab.id, initialURL: initialURL)
    return tab.id
  }

  /// The one diagnostic site for "a tab was added to the workspace", shared by
  /// Cmd-T, the sidebar "+" control, a routed popup and the replacement tab a
  /// last-tab close creates.
  private func logTabCreated(_ tabID: UUID, url: URL) {
    emit("tab:created(\(tabID.uuidString))")
    AppLog.session.info(
      "tab created id=\(tabID.uuidString, privacy: .public) url=\(URLLogSanitizer.sanitized(url), privacy: .public)"
    )
  }

  // MARK: - Tab lifecycle

  /// Creates a tab, its session and (once its container is in the window) its
  /// Chromium browser. Returns the new tab identifier, or nil during
  /// application termination.
  ///
  /// `select: false` inserts the tab behind the current selection: neither the
  /// selected tab nor the keyboard changes, and the new browser is created
  /// while its surface is hidden, so it can never take focus when it arrives.
  @discardableResult
  func createTab(url: URL? = nil, select: Bool = true) -> UUID? {
    guard !isTerminating else {
      // Section 10: shutdown must never produce a replacement tab.
      AppLog.session.error("refusing to create a tab while the application is terminating")
      return nil
    }
    let tab = BrowserTab(url: url)
    let initialURL = url ?? newTabURL
    withSelectionTransition {
      insertTab(tab, at: collection.tabs.count, select: select, initialURL: initialURL)
    }
    logTabCreated(tab.id, url: initialURL)
    return tab.id
  }

  /// Puts the most recently closed tab back (Cmd-Shift-T, section 22).
  ///
  /// The restored tab is a new BrowserTab with a new identifier and a brand new
  /// BrowserSession/CefBrowser. Nothing about the old runtime is reused.
  @discardableResult
  func reopenLastClosedTab() -> UUID? {
    guard !isTerminating else { return nil }
    guard let snapshot = collection.popRecentlyClosed() else {
      AppLog.session.debug("nothing to reopen: the recently closed stack is empty")
      return nil
    }
    let tab = BrowserTab(title: snapshot.title, url: snapshot.url)
    let initialURL = snapshot.url ?? newTabURL
    // The restored tab is selected, so it is a selection transition like any
    // other: the keyboard follows it only when page content had the keyboard.
    withSelectionTransition {
      insertTab(tab, at: snapshot.originalIndex, select: true, initialURL: initialURL)
    }
    emit("tab:reopened(\(tab.id.uuidString))")
    // The snapshot URL is a page the user visited and this line is captured into
    // a log file, so it is only ever reported sanitized.
    AppLog.session.info(
      "reopened a closed tab id=\(tab.id.uuidString, privacy: .public) url=\(URLLogSanitizer.sanitized(snapshot.url), privacy: .public)"
    )
    return tab.id
  }

  /// Selects a tab and moves the keyboard with it (section 16).
  ///
  /// The transition itself lives in `withSelectionTransition`, so this path and
  /// tab creation, reopening and closing behave identically.
  func selectTab(id: UUID) {
    guard let session = sessions[id], !session.isClosed else { return }
    guard collection.selectedTabID != id else { return }

    withSelectionTransition { collection.select(id) }
    emit("tab:selected")
    AppLog.session.info("tab selected id=\(id.uuidString, privacy: .public)")
  }

  /// Selects the tab at a zero-based index (Cmd-1...Cmd-8).
  @discardableResult
  func selectTab(at index: Int) -> Bool {
    guard let id = collection.tabID(at: index) else { return false }
    selectTab(id: id)
    return collection.selectedTabID == id
  }

  /// Selects the last tab (Cmd-9).
  @discardableResult
  func selectLastTab() -> Bool {
    guard let id = collection.tabs.last?.id else { return false }
    selectTab(id: id)
    return collection.selectedTabID == id
  }

  /// Closes one tab: the visible row goes now, the Chromium runtime goes when
  /// CEF confirms OnBeforeClose (section 6).
  func closeTab(id: UUID) {
    guard let session = sessions[id] else {
      // Unknown, or already released: closing is a safe no-op (section 29.14).
      AppLog.session.debug("close ignored for an unknown or already closed tab")
      return
    }
    let reason: TabCloseReason = isTerminating ? .applicationTerminating : .userClosed

    // The close is the selection transition: closing the selected tab selects
    // its neighbour (or, for the last tab, a replacement) and the keyboard is
    // handed over inside the transition, before the old session is asked to
    // close. Closing a background tab moves no selection, so the transition
    // leaves the active tab and the keyboard untouched.
    let result: TabCloseResult = withSelectionTransition {
      let result = collection.close(id, reason: reason)
      guard result.outcome != .unknownTab else { return result }

      // Mark the session as closing *before* the surface is synced: the sync
      // would treat a session that is neither visible nor known to be closing as
      // stale and remove its container while Chromium is still shutting the
      // browser down inside it. A session that never created a browser reaches
      // OnBeforeClose synchronously, so this ordering also has to hold for that
      // case.
      if !closingTabIDs.contains(id) {
        closingTabIDs.append(id)
      }
      if result.needsReplacementTab {
        // Section 20: the last ordinary tab close leaves a fresh usable tab, so
        // the window is never left with nothing to show. It is created inside
        // this transition, so it is selected and receives the keyboard exactly
        // like any other newly selected tab.
        let replacement = BrowserTab(url: nil)
        insertTab(replacement, at: collection.tabs.count, select: true, initialURL: newTabURL)
        logTabCreated(replacement.id, url: newTabURL)
      }
      return result
    }
    guard result.outcome != .unknownTab else { return }

    AppLog.session.info(
      "tab closing id=\(id.uuidString, privacy: .public) live=\(self.sessions.count, privacy: .public)"
    )
    // Nothing is waited for here: CloseBrowser returns immediately and
    // OnBeforeClose arrives through the message pump. The close releases only
    // this browser's own CEF focus and only this browser view's AppKit
    // responder, so it cannot take the keyboard away from the tab that just
    // inherited it.
    session.close(terminating: isTerminating)
    emit("tab:closed")
  }

  func closeSelectedTab() {
    guard let id = collection.selectedTabID else { return }
    closeTab(id: id)
  }

  /// Application termination: close every live browser, all at once.
  ///
  /// This is not the ordinary close path. It creates no replacement tab, records
  /// nothing in the recently-closed stack (section 10), and does not wait for
  /// one browser before asking the next - the browsers close in parallel and
  /// OnBeforeClose may arrive in any order.
  func requestCloseAllForTermination() {
    guard !isTerminating else { return }
    isTerminating = true
    let live = liveSessions
    AppLog.cef.info(
      "termination: closing \(live.count, privacy: .public) live browser session(s)")
    emit("session:close-all(count=\(live.count))")
    for session in live where !session.isClosed {
      if !closingTabIDs.contains(session.tabID) {
        closingTabIDs.append(session.tabID)
      }
      session.close(terminating: true)
    }
    syncSurface()
  }

  /// Navigates the selected tab. Used by the shortcut/menu layer and by tooling.
  @discardableResult
  func loadInSelectedTab(_ url: URL) -> Bool {
    guard let session = selectedSession else { return false }
    session.load(url)
    return true
  }

  // MARK: - Browser surface

  /// Adopts the AppKit host that shows the Chromium surfaces. Called by the
  /// representable; repeated calls with the same host are cheap.
  func attachSurfaceHost(_ host: BrowserSurfaceHostView) {
    surfaceHost = host
    syncSurface()
  }

  /// Makes the AppKit surface match the runtime registry.
  ///
  /// One container per live session, all of them in the hierarchy, only the
  /// selected one visible. A container is dropped only after its session was
  /// released by OnBeforeClose.
  func syncSurface() {
    guard let host = surfaceHost else { return }

    var live: [UUID: ChromiumContainerView] = [:]
    for tabID in liveSessionOrder where sessions[tabID] != nil {
      if let existing = containers[tabID] {
        live[tabID] = existing
      } else {
        let created = ChromiumContainerView(frame: host.bounds)
        created.autoresizingMask = [.width, .height]
        containers[tabID] = created
        live[tabID] = created
      }
    }

    // Containers the manager no longer owns are already empty; releasing them
    // here keeps the two registries from drifting apart.
    for (tabID, container) in containers where live[tabID] == nil {
      container.removeFromSuperview()
      containers.removeValue(forKey: tabID)
    }

    host.present(containers: live, selectedTabID: collection.selectedTabID)

    // Attach only after the containers are subviews of the host: a session
    // creates its Chromium browser once its container has a window.
    for tabID in liveSessionOrder {
      guard let session = sessions[tabID], let container = live[tabID] else { continue }
      session.attach(to: container)
    }
  }

  // MARK: - Session registry

  private func registerSession(for tabID: UUID, initialURL: URL) {
    let session = BrowserSession(tabID: tabID, initialURL: initialURL)
    session.onLifecycleEvent = { [weak self] event in
      self?.onLifecycleEvent?(event)
    }
    session.onTabMetadataChanged = { [weak self] session in
      self?.refreshTabMetadata(from: session)
    }
    session.onClosed = { [weak self] session in
      self?.sessionDidClose(session)
    }
    session.onOpenNewTabRequest = { [weak self] session, url in
      self?.openPopupInNewTab(url: url, from: session)
    }
    sessions[tabID] = session
    onWillPublish?()
    liveSessionCount = sessions.count
    // No surface work here: the caller's selection transition publishes and
    // syncs, which is what keeps "a container becomes visible" ordered before
    // "a browser is created in it" for a newly created tab.
  }

  /// One Chromium callback updates exactly one tab: the session identity decides
  /// which, never a "current browser" (section 13).
  private func refreshTabMetadata(from session: BrowserSession) {
    guard let index = collection.index(of: session.tabID) else { return }
    var tab = collection.tabs[index]
    // A restored tab is seeded with the closed tab's title/URL; Chromium
    // replaces them as soon as it reports its own.
    if !session.title.isEmpty { tab.title = session.title }
    if session.url != nil { tab.url = session.url }
    tab.isLoading = session.isLoading
    guard collection.refresh(tab) else { return }
    publishStateOnly()
  }

  private func sessionDidClose(_ session: BrowserSession) {
    let tabID = session.tabID
    guard sessions[tabID] === session else { return }
    sessions.removeValue(forKey: tabID)
    closingTabIDs.removeAll { $0 == tabID }
    onWillPublish?()
    liveSessionCount = sessions.count
    AppLog.cef.info(
      "session released id=\(session.id.uuidString, privacy: .public) live=\(self.sessions.count, privacy: .public)"
    )
    emit("session:released")
    // Only now may the container go: OnBeforeClose has run, so nothing Chromium
    // owns is attached to it any more.
    if let container = containers.removeValue(forKey: tabID) {
      container.removeFromSuperview()
    }
    syncSurface()
    onLiveSessionDidClose?(session)
  }

  /// Routes an ordinary target=_blank / window.open request to a managed tab
  /// (section 26). The unmanaged CEF popup was already cancelled by the bridge.
  private func openPopupInNewTab(url: String, from session: BrowserSession) {
    guard !isTerminating else { return }
    guard !url.isEmpty, let target = URL(string: url) else {
      AppLog.session.error("popup request without a usable URL")
      return
    }
    // The URL is logged sanitized: a popup URL routinely carries an OAuth code
    // or a signature (section 28).
    let loggedURL = URLLogSanitizer.sanitized(target)
    AppLog.session.info("popup routed to a managed tab url=\(loggedURL, privacy: .public)")
    emit("popup:new-tab(\(loggedURL))")
    createTab(url: target)
  }

  // MARK: - State publication

  private func publishState() {
    publishStateOnly()
    syncSurface()
  }

  private func publishStateOnly() {
    onWillPublish?()
    tabs = collection.tabs
    selectedTabID = collection.selectedTabID
    recentlyClosed = collection.recentlyClosed
  }

  private func emit(_ event: String) {
    onLifecycleEvent?(event)
  }
}
