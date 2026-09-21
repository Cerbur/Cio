//
//  BrowserSessionManager.swift
//  NativeBrowser
//
//  Runtime owner for Chromium sessions and stable browser surfaces.
//
//  Milestone 4 deliberately keeps workspace/domain policy out of this type.
//  BrowserWorkspaceStore owns Spaces, BrowserTabs, ordering, selection and
//  recently-closed policy. This manager owns only BrowserSession objects,
//  closing-session retention, ChromiumContainerView objects and the stable
//  BrowserSurfaceHostView synchronization.
//

import AppKit
import Foundation

@MainActor
final class BrowserSessionManager: ObservableObject {
  // MARK: - Published runtime state

  /// Every Chromium runtime still owned by the application, including sessions
  /// whose visible tab has already been removed but which await OnBeforeClose.
  @Published private(set) var liveSessionCount = 0

  // MARK: - Hooks

  /// Lifecycle milestones used by the verification tooling. Diagnostics only.
  var onLifecycleEvent: ((String) -> Void)?

  /// Typed notification used by ApplicationRuntime's termination coordinator.
  /// The callback carries the exact session released by OnBeforeClose.
  var onLiveSessionDidClose: ((BrowserSession) -> Void)?

  /// Runtime metadata callback. BrowserWorkspaceStore uses the session identity
  /// to update exactly one BrowserTab in the pure domain model.
  var onTabMetadataChanged: ((BrowserSession) -> Void)?

  /// Popup callback. The workspace store resolves the source session's Space.
  var onOpenNewTabRequest: ((BrowserSession, String) -> Void)?

  /// Application-level history callback. The manager forwards typed events but
  /// does not own history records.
  var onMainFrameLoadFinished: ((BrowserSession, URL) -> Void)?
  var onTitleChanged: ((BrowserSession) -> Void)?

  /// Application-level download callbacks. The manager remains a runtime
  /// session owner and only forwards value events.
  var onDownloadRequested: ((BrowserSession, UInt32, URL, String, DownloadMetadata) -> String)?
  var onDownloadUpdated: ((BrowserSession, BrowserDownloadUpdate) -> Void)?

  /// Called when the runtime registry changes so the workspace store can redraw
  /// its status bar without becoming a second runtime registry.
  var onRuntimeStateChanged: (() -> Void)?

  // MARK: - Runtime registry

  private var sessions: [UUID: BrowserSession] = [:]
  /// Registration order keeps runtime diagnostics and surface updates
  /// deterministic without making this manager a domain tab-order owner.
  private var sessionOrder: [UUID] = []
  /// Sessions requested to close, retained until the typed OnBeforeClose path.
  private var closingTabIDs: [UUID] = []
  private var containers: [UUID: ChromiumContainerView] = [:]
  private weak var surfaceHost: BrowserSurfaceHostView?
  private var selectedSurfaceTabID: UUID?

  private(set) var isTerminating = false

  init() {}

  // MARK: - Queries

  func session(for tabID: UUID) -> BrowserSession? {
    sessions[tabID]
  }

  var hasLiveSessions: Bool { !sessions.isEmpty }

  /// Every live runtime in deterministic registration order, followed by any
  /// closing runtime not present in that order.
  var liveSessions: [BrowserSession] {
    liveSessionOrder.compactMap { sessions[$0] }
  }

  var liveSessionOrder: [UUID] {
    var seen = Set<UUID>()
    var order: [UUID] = []
    for tabID in sessionOrder + closingTabIDs
    where sessions[tabID] != nil && seen.insert(tabID).inserted {
      order.append(tabID)
    }
    return order
  }

  func isClosing(tabID: UUID) -> Bool {
    closingTabIDs.contains(tabID)
  }

  /// The Chromium identifier of every live session that has completed browser
  /// creation. This is a runtime diagnostic, not a second ownership registry.
  var liveBrowserIdentifiers: [Int] {
    liveSessions.compactMap { $0.browserIdentifier }
  }

  // MARK: - Runtime lifecycle

  /// Creates exactly one runtime for a domain tab identity. The manager does
  /// not store the tab or decide where it belongs; the workspace store does.
  @discardableResult
  func createSession(
    for tabID: UUID,
    initialURL: URL,
    initialTitle: String = ""
  ) -> BrowserSession? {
    guard !isTerminating else {
      AppLog.session.error("refusing to create a session while the application is terminating")
      return nil
    }
    guard sessions[tabID] == nil else {
      AppLog.session.error("refusing to create a duplicate session for a tab")
      return sessions[tabID]
    }

    let session = BrowserSession(
      tabID: tabID,
      initialURL: initialURL,
      initialTitle: initialTitle)
    session.onLifecycleEvent = { [weak self] event in
      self?.onLifecycleEvent?(event)
    }
    session.onTabMetadataChanged = { [weak self] session in
      self?.onTabMetadataChanged?(session)
    }
    session.onClosed = { [weak self] session in
      self?.sessionDidClose(session)
    }
    session.onOpenNewTabRequest = { [weak self] session, url in
      self?.onOpenNewTabRequest?(session, url)
    }
    session.onMainFrameLoadFinished = { [weak self] session, url in
      self?.onMainFrameLoadFinished?(session, url)
    }
    session.onTitleChanged = { [weak self] session in
      self?.onTitleChanged?(session)
    }
    session.onDownloadRequested = {
      [weak self] session, downloadID, sourceURL, suggestedFileName, metadata in
      self?.onDownloadRequested?(
        session, downloadID, sourceURL, suggestedFileName, metadata) ?? ""
    }
    session.onDownloadUpdated = { [weak self] session, update in
      self?.onDownloadUpdated?(session, update)
    }

    sessions[tabID] = session
    sessionOrder.append(tabID)
    publishRuntimeState()
    return session
  }

  /// Requests destruction of exactly one runtime. The session remains in the
  /// registry until BrowserBridge reports OnBeforeClose.
  func requestClose(tabID: UUID, terminating: Bool = false) {
    guard let session = sessions[tabID], !session.isClosed else { return }
    guard terminating || !isTerminating else { return }

    if terminating {
      isTerminating = true
    }
    if !closingTabIDs.contains(tabID) {
      closingTabIDs.append(tabID)
    }
    session.close(terminating: terminating)
    syncSurface()
  }

  /// Application termination: request every runtime across every Space in one
  /// turn. The workspace store never creates replacements during this path.
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

  /// Manual diagnostic hook for callers that explicitly need to release a
  /// browser view. Normal application termination never uses this path: it
  /// waits for every typed OnBeforeClose callback instead of falling back.
  func releaseBrowserViews() {
    for session in liveSessions where !session.isClosed {
      session.releaseBrowserView()
    }
  }

  // MARK: - Surface ownership

  /// Attaches the one stable AppKit host for the application window.
  func attachSurfaceHost(_ host: BrowserSurfaceHostView) {
    surfaceHost = host
    syncSurface()
  }

  /// Publishes the effective selected tab from the workspace owner. The manager
  /// accepts only this derived selection; it does not maintain a tab list or a
  /// second selected-tab source of truth.
  func setSelectedSurfaceTabID(_ tabID: UUID?) {
    selectedSurfaceTabID = tabID
    syncSurface()
  }

  /// Keeps one container for every live session and makes only the workspace's
  /// effective selected tab visible. Inactive Space sessions remain mounted and
  /// live; switching Spaces never reaches BrowserBridge::CreateBrowser.
  private func syncSurface() {
    guard let host = surfaceHost else { return }

    var live: [UUID: ChromiumContainerView] = [:]
    for tabID in liveSessionOrder {
      guard sessions[tabID] != nil else { continue }
      if let existing = containers[tabID] {
        live[tabID] = existing
      } else {
        let created = ChromiumContainerView(frame: host.bounds)
        created.autoresizingMask = [.width, .height]
        containers[tabID] = created
        live[tabID] = created
      }
    }

    let staleContainers = containers.filter { live[$0.key] == nil }
    for (tabID, container) in staleContainers {
      container.removeFromSuperview()
      containers.removeValue(forKey: tabID)
    }

    host.present(containers: live, selectedTabID: selectedSurfaceTabID)

    // Attach after the containers are subviews. BrowserSession creates its CEF
    // browser only once the container has a window, and never on a visibility
    // or selection update.
    for tabID in liveSessionOrder {
      guard let session = sessions[tabID], let container = live[tabID] else { continue }
      session.attach(to: container)
    }
  }

  // MARK: - Runtime callbacks

  private func sessionDidClose(_ session: BrowserSession) {
    let tabID = session.tabID
    guard sessions[tabID] === session else { return }

    sessions.removeValue(forKey: tabID)
    sessionOrder.removeAll { $0 == tabID }
    closingTabIDs.removeAll { $0 == tabID }
    liveSessionCount = sessions.count
    onRuntimeStateChanged?()
    AppLog.cef.info(
      "session released id=\(session.id.uuidString, privacy: .public) live=\(self.sessions.count, privacy: .public)"
    )
    emit("session:released")

    // OnBeforeClose has already run, so the Chromium view is no longer owned by
    // CEF and the container may finally leave the stable host.
    if let container = containers.removeValue(forKey: tabID) {
      container.removeFromSuperview()
    }
    syncSurface()
    onLiveSessionDidClose?(session)
  }

  private func publishRuntimeState() {
    liveSessionCount = sessions.count
    onRuntimeStateChanged?()
  }

  private func emit(_ event: String) {
    onLifecycleEvent?(event)
  }
}
