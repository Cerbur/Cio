//
//  BrowserSession.swift
//  Cio
//
//  Runtime-only browser session: one Chromium browser instance for one tab
//  (ARCHITECTURE.md section 7).
//
//  Deliberately not Codable and never persisted: the persisted domain model is
//  the separate BrowserTab type, which contains no Chromium object and no session.
//
//  This class owns no Chromium type: everything goes through BrowserBridge.
//
//  Milestone 2 added the UI-facing navigation state (section 20 of
//  ARCHITECTURE.md) and the address-field editing state. Milestone 3 adds the
//  tab identity, the typed close notification the session manager waits on, and
//  the per-session metadata notification that keeps one browser's callbacks from
//  touching another tab.
//
//  The editing flag lives on the session on purpose: the "do not overwrite what
//  the user is typing" rule is stated once, in
//  BrowserSession.updateNavigationState / AddressFieldModel.applyBrowserURL,
//  instead of being split between the toolbar and the bridge. Because every
//  session owns its own AddressFieldModel, a background tab's URL callback
//  cannot reach the address field of the selected tab at all.
//

import CioUI
import CioModel
import Combine
import CioChromium
import CioEngine
import AppKit
import Foundation

private enum BrowserSessionCloseState {
  case open
  case userClosePending
  case accepted
  case applicationTerminating
  case closed
}

@MainActor
final class BrowserSession: NSObject, ObservableObject, Identifiable {
  /// Runtime identity of this session, distinct from the tab identifier: a tab
  /// can be reopened and its runtime replaced, and the log has to be able to
  /// tell those two apart.
  let id = UUID()

  /// The BrowserTab this session renders. A pin-to-temporary handoff changes
  /// this key while preserving the runtime identity and the running page.
  private(set) var tabID: UUID

  /// URL the session opens when its browser is first created.
  let initialURL: URL
  private var requestedURL: URL

  @Published private(set) var title = ""
  @Published private(set) var url: URL?
  /// Icon URLs reported by Chromium for this live page.
  @Published private(set) var faviconURLs: [URL] = []
  /// Chromium handles SVG/CSS, page credentials and multi-scale decoding.
  @Published private(set) var faviconImage: NSImage?
  /// Encoded native representations saved alongside the tab's title and URL.
  private(set) var faviconData: Data?
  @Published private(set) var isLoading = false
  @Published private(set) var loadingProgress: Double = 0
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  @Published private(set) var lastErrorCode: Int?
  @Published private(set) var rendererCrashed = false
  @Published private(set) var extensionActions: [BrowserExtensionAction] = []

  /// True once the Chromium browser object exists.
  @Published private(set) var hasBrowser = false
  @Published private(set) var isDevToolsOpen = false
  private var devToolsWindow: NSWindow?
  /// True once Chromium destroyed the browser; the session cannot be reused.
  private(set) var isClosed = false
  /// True after the first load finished (successfully or not).
  @Published private(set) var hasFinishedFirstLoad = false

  /// How many Chromium browsers this session has created. Must stay at 1 for a
  /// session's lifetime: navigation, resizing, SwiftUI re-renders and - in
  /// Milestone 3 - tab switching must never build a second browser.
  private(set) var browserCreationCount = 0

  /// Chromium's identifier for this session's browser, or nil before it exists.
  /// Used by the multi-tab integration test to prove that two tabs really do own
  /// two distinct browsers.
  var browserIdentifier: Int? {
    guard let bridge, bridge.browserIdentifier >= 0 else { return nil }
    return Int(bridge.browserIdentifier)
  }

  /// Incremented every time Chromium reports a different main-frame URL. Used
  /// by the integration self-test to prove that a navigation actually happened
  /// rather than merely finishing a cached load before it could be observed.
  private(set) var mainFrameURLChangeCount = 0

  /// Incremented every time Chromium starts loading. A reload does not change
  /// the main-frame URL, so this is what proves that a reload reached Chromium.
  private(set) var loadStartCount = 0

  /// Incremented for each successful main-frame OnLoadEnd callback, including
  /// reloads and Back/Forward loads whose URL may not change.
  private(set) var successfulMainFrameLoadCount = 0

  /// Editing state of the native address field. One per session, so a background
  /// tab's navigation callbacks can never move the selected tab's text.
  let addressField = AddressFieldModel()
  @Published private(set) var findState = BrowserFindState()
  private var findGeneration = 0
  private var isEditingFindField = false
  private var restorePageAfterFind = false

  /// True while the native address field owns the keyboard. Used to keep the
  /// toolbar's focus handling from fighting Chromium for first responder.
  private(set) var isEditingAddressField = false

  /// True while this session's page content is supposed to own the keyboard.
  ///
  /// This is the state the *asynchronous* half of Chromium answers to. Chromium
  /// creates a browser after the tab may already have been hidden again, or
  /// after the user moved the keyboard into the native address field, so "my
  /// browser was just created" is not by itself a reason to take AppKit's first
  /// responder. `focusPage()` sets this, `blur()` clears it, and the one
  /// selection transition in BrowserSessionManager sets it on every tab change.
  ///
  /// A session starts wanting the keyboard, so the tab the application opens at
  /// launch behaves like Milestone 2: clicking and typing reach the page without
  /// an extra click. A browser created while its tab is not the visible selected
  /// surface never takes focus, whatever this flag says.
  private(set) var wantsPageFocus = true

  /// Lifecycle milestones, for logging and the verification tooling. Diagnostics
  /// only: BrowserSessionManager never derives ownership from these strings.
  var onLifecycleEvent: ((String) -> Void)?

  /// Typed close notification (Milestone 3 section 7).
  ///
  /// Delivered exactly once, after Chromium reported OnBeforeClose. The manager
  /// releases the runtime container here and nowhere else, so a session cannot
  /// be discarded before Chromium has finished with it.
  var onClosed: ((BrowserSession) -> Void)?

  /// Chromium accepted an ordinary user close after beforeunload completed. The
  /// workspace commits the domain removal only after this signal.
  var onCloseAccepted: ((BrowserSession) -> Void)?

  /// Chromium cancelled an ordinary close, usually because the user rejected the
  /// beforeunload confirmation. The workspace remains unchanged.
  var onCloseCancelled: ((BrowserSession) -> Void)?

  /// Typed notification that a Chromium callback changed state the tab list
  /// shows. Carries this session, so one browser's callback can only ever update
  /// its own tab (Milestone 3 section 13).
  var onTabMetadataChanged: ((BrowserSession) -> Void)?

  /// Typed notification that Chromium asked for a popup (`target=_blank`,
  /// `window.open`). The bridge has already cancelled the unmanaged native
  /// window; the manager decides where the URL opens (Milestone 3 section 26).
  var onOpenNewTabRequest: ((BrowserSession, String) -> Void)?
  var onOpenExtensionTabRequest: ((BrowserSession, String, Bool) -> Void)?

  /// Typed successful top-level load event. This is intentionally not derived
  /// from the address callback: redirects and failed/provisional URLs do not
  /// represent completed history visits.
  var onMainFrameLoadFinished: ((BrowserSession, URL) -> Void)?

  /// Title changes update an existing history row without incrementing its
  /// visit count.
  var onTitleChanged: ((BrowserSession) -> Void)?

  /// Download events remain value-only at the Swift boundary. The destination
  /// request is synchronous from Chromium's perspective but does not retain a Chromium
  /// callback in Swift.
  var onDownloadRequested: ((BrowserSession, UInt32, URL, String, DownloadMetadata) -> String)?
  var onDownloadUpdated: ((BrowserSession, BrowserDownloadUpdate) -> Void)?

  /// The most recent completed main-frame URL, used to associate a title that
  /// arrives after OnLoadEnd with the visit that just completed.
  private(set) var lastSuccessfulMainFrameURL: URL?

  /// Chromium can deliver OnLoadEnd and a title for its built-in error document
  /// after OnLoadError. Keep that failed navigation separate from the last
  /// committed page so it cannot create a history row or overwrite the last
  /// successful page's title.
  private var lastMainFrameLoadFailed = false

  private var bridge: BrowserBridge?
  private var browserCreationScheduled = false
  private var lastAppliedDarkAppearance: Bool?
  private weak var containerView: ChromiumContainerView?
  private var didStartLoading = false
  private var didReceiveMainFrameURL = false
  private var closeState: BrowserSessionCloseState = .open

  init(tabID: UUID, initialURL: URL, initialTitle: String = "", initialFaviconData: Data? = nil) {
    self.tabID = tabID
    self.initialURL = initialURL
    self.requestedURL = initialURL
    self.title = BrowserPresentationLimits.title(initialTitle)
    self.url = initialURL
    let artwork = initialFaviconData.flatMap { BrowserArtwork.normalized($0, as: .favicon) }
    self.faviconData = artwork
    self.faviconImage = artwork.flatMap { BrowserArtwork.decode($0, as: .favicon) }
      .map { NSImage(cgImage: $0, size: .zero) }
    super.init()
    addressField.applyBrowserURL(initialURL)
  }

  // MARK: - Navigation state

  /// Only the runtime registry reassigns ownership; this never navigates or
  /// replaces the bridge, native container, address editor or page state.
  func transferOwnership(to tabID: UUID) {
    self.tabID = tabID
  }

  /// The state the navigation UI renders. Chromium is the source of truth for
  /// every field.
  var navigationState: NavigationState {
    NavigationState(
      url: url,
      title: title,
      isLoading: isLoading,
      loadingProgress: loadingProgress,
      canGoBack: canGoBack,
      canGoForward: canGoForward)
  }

  var siteInformation: SiteInformation {
    let info = rendererCrashed ? nil : bridge?.connectionInfo()
    return SiteInformation(
      url: url, title: title, isLoading: isLoading,
      loadFailed: lastErrorCode != nil || rendererCrashed,
      entryURL: info.flatMap { URL(string: $0.url) },
      usesTLS: info?.usesTLS ?? false,
      certificateValid: info?.certificateValid ?? false,
      hasInsecureContent: info?.hasInsecureContent ?? false,
      certificateChain: info?.certificateChain ?? [])
  }

  // MARK: - View attachment

  func executeExtensionAction(_ identifier: String) {
    guard !isClosed, extensionActions.contains(where: { $0.id == identifier && $0.isEnabled }) else { return }
    // A deferred focusPage() would run after the transient popup opens and
    // dismiss it. Restore the page's focus policy synchronously for this user
    // action; the extension host owns the next first-responder handoff.
    wantsPageFocus = true
    bridge?.setFocus(true)
    bridge?.executeExtensionAction(identifier)
  }

  func openExtensionManager() { bridge?.openExtensionManager() }
  func openExtensionStore() { bridge?.openExtensionStore() }

  func showPendingPasswordPrompt() -> Bool {
    guard !isClosed, !rendererCrashed, let bridge else { return false }
    addressField.cancelEditing()
    setAddressFieldFocused(false)
    closeFindBar()
    wantsPageFocus = true
    bridge.setFocus(true)
    return bridge.showPendingPasswordPrompt()
  }

  func browserBridgeDidChangeExtensions(_ bridge: BrowserBridge) {
    guard self.bridge === bridge, !isClosed else { return }
    extensionActions = bridge.extensionActions().compactMap { value in
      guard let id = value["id"] as? String, let name = value["name"] as? String,
            let title = value["title"] as? String, let enabled = value["enabled"] as? Bool,
            let icon = value["icon"] as? Data else { return nil }
      return BrowserExtensionAction(id: id, name: name, title: title, isEnabled: enabled, iconPNG: icon)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Binds the session to the AppKit container that will host the Chromium
  /// view. The browser itself is created once the container is in a window.
  func attach(to view: ChromiumContainerView) {
    if containerView === view {
      return
    }
    configureFindBar(in: view)
    if let existing = containerView, existing !== view, bridge != nil {
      // The manager moved this session's surface to another container (for
      // example because SwiftUI re-created the representable's view): move the
      // existing browser instead of creating a second one.
      existing.delegate = nil
      containerView = view
      view.delegate = self
      bridge?.reparent(to: view.pageContentView)
      if isDevToolsOpen {
        view.showDevToolsPane()
        bridge?.setDevToolsEmulationHostView(view.devToolsEmulationHostView)
        if let host = devToolsWindow?.contentView {
          view.setDevToolsDocked(false)
          bridge?.reparentDevTools(to: host)
        } else {
          bridge?.reparentDevTools(to: view.devToolsHostView)
        }
        existing.hideDevToolsPane()
      }
      return
    }
    containerView = view
    view.delegate = self
    createBrowserIfPossible()
  }

  private func createBrowserIfPossible() {
    guard !isClosed, bridge == nil, let view = containerView, view.window != nil else {
      return
    }
    // AppKit notifies a parent before propagating its window to the child
    // hosting WebContents. Native Chromium requires that child's real window.
    guard view.pageContentView.window != nil else {
      guard !browserCreationScheduled else { return }
      browserCreationScheduled = true
      emit("browser:waiting-for-content-window")
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.browserCreationScheduled = false
        self.createBrowserIfPossible()
      }
      return
    }
    let bridge = BrowserBridge(parentView: view.pageContentView)
    bridge.delegate = self
    self.bridge = bridge
    // The initial load does not go through load(_:), so it is logged here; the
    // URL is sanitized like every other URL that reaches a log (the
    // Objective-C++ bridge deliberately does not log it at all).
    AppLog.navigation.info("load \(URLLogSanitizer.sanitized(self.requestedURL), privacy: .public)")
    bridge.loadURL(requestedURL.absoluteString)
  }

  func setDarkAppearance(_ dark: Bool) {
    guard lastAppliedDarkAppearance != dark, let bridge,
      bridge.setDarkAppearance(dark)
    else { return }
    lastAppliedDarkAppearance = dark
  }

  /// Whether this session's container is the visible selected surface. The focus
  /// rules are stated in terms of it, so focus diagnostics report it too.
  var isSurfaceVisible: Bool { containerView?.isSurfaceVisible ?? false }

  /// True while this session's page content owns the keyboard - or is the session
  /// the keyboard was handed to and is still waiting for it. A new tab's
  /// container may not be in a window yet and its Chromium browser is created
  /// asynchronously, so AppKit's first responder alone is not enough: a hand-over
  /// that has not physically happened yet would look like "the keyboard is
  /// somewhere else", and the keyboard would stop following page content.
  ///
  /// This is the state a selection transition captures from the outgoing session.
  var ownsPageKeyboard: Bool {
    holdsAppKitKeyboardFocus || wantsPageFocus || isEditingFindField
  }

  /// True while AppKit's keyboard focus is inside this session's Chromium
  /// surface. A tab switch only moves the keyboard when the page had it, so a
  /// switch never pulls focus out of the native address field.
  var holdsAppKitKeyboardFocus: Bool {
    guard let view = containerView, let window = view.window,
      let responder = window.firstResponder
    else { return false }
    if view.findBar.hasKeyboardFocus { return false }
    if responder === view { return true }
    if let responderView = responder as? NSView {
      return responderView.isDescendant(of: view)
    }
    return false
  }

  // MARK: - Navigation

  /// Loads `url` in Chromium.
  ///
  /// The URL handed to the bridge is the original, complete URL; only the two
  /// observability strings below are sanitized (see URLLogSanitizer). A browser
  /// URL may carry a token, an OAuth code or a signature, so it must never reach
  /// a log or a lifecycle trace in full.
  func load(_ url: URL) {
    guard !isClosed else { return }
    // Input may arrive before the native host has a window. Keep the latest
    // request so browser creation cannot silently navigate the original URL.
    requestedURL = url
    beginNavigation()
    let loggedURL = URLLogSanitizer.sanitized(url)
    AppLog.navigation.info("load \(loggedURL, privacy: .public)")
    onLifecycleEvent?("navigation:load(\(loggedURL))")
    bridge?.loadURL(url.absoluteString)
  }

  func goBack() {
    guard canGoBack else {
      AppLog.navigation.debug("back ignored: no history entry")
      return
    }
    beginNavigation()
    AppLog.navigation.info("back")
    onLifecycleEvent?("navigation:back")
    bridge?.goBack()
  }

  func goForward() {
    guard canGoForward else {
      AppLog.navigation.debug("forward ignored: no forward entry")
      return
    }
    beginNavigation()
    AppLog.navigation.info("forward")
    onLifecycleEvent?("navigation:forward")
    bridge?.goForward()
  }

  func reload() {
    beginNavigation()
    AppLog.navigation.info("reload")
    onLifecycleEvent?("navigation:reload")
    bridge?.reload()
  }

  func reloadIgnoringCache() {
    guard !isClosed, hasBrowser else { return }
    beginNavigation()
    AppLog.navigation.info("reload ignoring cache")
    onLifecycleEvent?("navigation:reloadIgnoringCache")
    bridge?.reloadIgnoringCache()
  }

  func stop() {
    AppLog.navigation.info("stop")
    onLifecycleEvent?("navigation:stop")
    bridge?.stopLoading()
  }

  func zoomIn() {
    guard closeState == .open, hasBrowser, !rendererCrashed else { return }
    if let percent = bridge?.zoomIn(), percent > 0 { containerView?.showPageZoom(percent) }
  }

  func zoomOut() {
    guard closeState == .open, hasBrowser, !rendererCrashed else { return }
    if let percent = bridge?.zoomOut(), percent > 0 { containerView?.showPageZoom(percent) }
  }

  func resetZoom() {
    guard closeState == .open, hasBrowser, !rendererCrashed else { return }
    if let percent = bridge?.resetZoom(), percent > 0 { containerView?.showPageZoom(percent) }
  }

  func toggleDevTools() {
    guard closeState == .open, let bridge else { return }
    if isDevToolsOpen {
      bridge.closeDevTools()
    } else {
      showDevTools()
    }
  }

  private func showDevTools() {
    guard closeState == .open, !isDevToolsOpen, let bridge, let containerView else { return }
    containerView.showDevToolsPane()
    bridge.setDevToolsEmulationHostView(containerView.devToolsEmulationHostView)
    isDevToolsOpen = bridge.showDevTools(in: containerView.devToolsHostView)
    if !isDevToolsOpen { containerView.hideDevToolsPane() }
  }

  func viewPageSource() {
    guard closeState == .open else { return }
    bridge?.viewPageSource()
  }

  func browserBridge(_ bridge: BrowserBridge, didRequestInspectNode backendNodeID: Int) {
    guard acceptsCallback(from: bridge), isSurfaceVisible else { return }
    showDevTools()
    bridge.revealDevToolsNode(backendNodeID)
    devToolsWindow?.makeKeyAndOrderFront(nil)
  }

  /// Starts a download through Chromium's browser host. This is used only by the
  /// deterministic real-Chromium verifier; normal user downloads enter through
  /// page actions and the same native download callbacks.
  func startDownload(_ url: URL) {
    bridge?.startDownloadURL(url.absoluteString)
  }

  /// Sends one synthetic page click for the deterministic beforeunload
  /// integration driver. Production close behavior never uses this hook.
  func sendTestUserActivation() {
    bridge?.sendTestUserActivation()
  }

  private func beginNavigation() {
    containerView?.dismissPageZoom()
    lastErrorCode = nil
    lastMainFrameLoadFailed = false
    rendererCrashed = false
  }

  /// Reload when the page is idle, stop when it is loading (Milestone 2,
  /// section 11). The decision comes from Chromium's loading state, never from a
  /// timer.
  func reloadOrStop() {
    if isLoading {
      stop()
    } else {
      reload()
    }
  }

  func focus() {
    bridge?.setFocus(true)
  }

  func capturePagePreview(_ completion: @escaping @MainActor (NSImage?) -> Void) {
    guard !isClosed, didReceiveMainFrameURL, !lastMainFrameLoadFailed, let bridge else { completion(nil); return }
    bridge.capturePagePreview(maximumPixelSize: BrowserArtwork.Kind.preview.pixelLimit) { image in completion(image) }
  }

  /// Releases the keyboard from this session's page content.
  ///
  /// Chromium focus is released through the bridge, which clears AppKit's first
  /// responder only when it belongs to that browser's own view
  /// (NBResponderBelongsToView), so releasing one tab never disturbs the native
  /// address field's field editor. A session whose browser is still being
  /// created has no bridge to do that, so the container's own first-responder
  /// status is cleared here: `focusPage()` makes the container first responder
  /// while a browser is pending, and neither a hidden surface nor a session that
  /// is no longer selected may keep the keyboard.
  func blur() {
    wantsPageFocus = false
    if holdsAppKitKeyboardFocus || containerView?.findBar.hasKeyboardFocus == true {
      containerView?.window?.makeFirstResponder(nil)
    }
    isEditingFindField = false
    bridge?.setFindBarFocused(false)
    bridge?.setFocus(false)
  }

  /// Clears all focus owned by this tab before its domain identity leaves the
  /// workspace. AppKit's field editor is shared by every native address field,
  /// so leaving it alive while the selected tab is removed can make the
  /// replacement tab inherit an editing session.
  func releaseFocusBeforeTabRemoval() {
    wantsPageFocus = false
    isEditingAddressField = false
    isEditingFindField = false
    resetFindStateForClose()
    addressField.endEditing()
    containerView?.window?.makeFirstResponder(nil)
    bridge?.setFocus(false)
  }

  /// Completes the close by releasing the Chromium view, which is what
  /// destroys the browser. Used when Chromium does not deliver DoClose (see
  /// BrowserBridge.releaseBrowserView). Safe to call more than once.
  func releaseBrowserView() {
    guard !isClosed else { return }
    bridge?.releaseBrowserView()
  }

  /// Requests browser destruction. Safe to call more than once.
  ///
  /// `terminating` is passed through to the bridge: while the whole application
  /// is quitting, releasing AppKit's first responder unconditionally is correct
  /// (it is the Milestone 2 Cmd+Q fix). For an ordinary background-tab close it
  /// is not - it would take the keyboard away from the active tab or from the
  /// native address field.
  func close(terminating: Bool = false) {
    guard !isClosed else { return }
    if terminating {
      // Termination must retain an ordinary close that Chromium has accepted but
      // has not yet completed with OnBeforeClose. The workspace may already
      // have installed a last-tab replacement by then, while this runtime
      // still remains live and must stay in the close barrier until its typed
      // callback arrives.
      guard closeState != .applicationTerminating else { return }
      let closeWasAlreadyAccepted = closeState == .accepted
      closeState = .applicationTerminating
      // Chromium has already entered its normal close sequence. Calling
      // CloseBrowser(true) again at this point can interrupt the pending
      // platform-view teardown; keep pumping until its typed OnBeforeClose
      // arrives. Termination still force-closes the open/beforeunload-pending
      // cases below.
      if closeWasAlreadyAccepted {
        return
      }
    } else {
      guard closeState == .open else { return }
      closeState = .userClosePending
    }
    guard let bridge else {
      notifyCloseAccepted()
      closeState = .closed
      isClosed = true
      resetFindStateForClose()
      // Reported before the typed callback below so the lifecycle trace keeps
      // the "browser:closed" -> "termination:browsers-closed" order the
      // Milestone 2 verification checks.
      onLifecycleEvent?("browser:closed(before-creation)")
      onClosed?(self)
      return
    }
    bridge.close(forApplicationTermination: terminating)
  }

  /// Records that the native address field gained or lost the keyboard.
  ///
  /// Lives here rather than in BrowserSession+Commands.swift because it mutates
  /// a private(set) property; the command layer calls it.
  func setAddressFieldFocused(_ focused: Bool) {
    isEditingAddressField = focused
    if focused {
      // Chromium must not keep focus at the same time: otherwise both the field
      // editor and the Chromium view believe they own the keyboard, and typing
      // can reach the page while the caret sits in the address bar.
      wantsPageFocus = false
      bridge?.setFocus(false)
    } else {
      addressField.endEditing()
    }
  }

  /// Whether this session's surface may own the keyboard right now. Both halves
  /// of `focusPage()` consult it: a hidden surface is never first responder, and
  /// a session that no longer wants the keyboard must not have it handed over
  /// late.
  private var canTakePageFocus: Bool {
    !isClosed && wantsPageFocus && !isEditingAddressField && !isEditingFindField
      && containerView?.isSurfaceVisible == true && containerView?.window?.attachedSheet == nil
  }

  /// Returns the keyboard to Chromium.
  ///
  /// The main-queue hop matters: this is normally called from a control action
  /// while AppKit is still completing its own focus change, and a re-entrant
  /// first-responder change is ignored. One hop lets that settle; it is the
  /// native way to defer to the end of the event, not a delay.
  ///
  /// Only the visible selected surface may take the keyboard, and both steps
  /// re-check that (an explicit `makeFirstResponder` succeeds even for a hidden
  /// view), so a request issued while the tab was selected cannot focus a
  /// surface that has been hidden since.
  func focusPage() {
    guard !isClosed, let view = containerView, view.isSurfaceVisible else { return }
    wantsPageFocus = true
    isEditingFindField = false
    bridge?.setFindBarFocused(false)
    view.window?.makeFirstResponder(view)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.canTakePageFocus else { return }
      self.focus()
    }
  }

  // MARK: - Per-tab find

  private func configureFindBar(in view: ChromiumContainerView) {
    view.findBar.apply(findState)
    view.findBar.onQueryChanged = { [weak self] in self?.setFindQuery($0) }
    view.findBar.onNavigate = { [weak self] in self?.navigateFind(forward: $0) }
    view.findBar.onClose = { [weak self] in self?.closeFindBar() }
    view.findBar.onFocusChanged = { [weak self] in self?.findFieldFocusChanged($0) }
  }

  private func updateFindUI() {
    containerView?.findBar.apply(findState)
    containerView?.needsLayout = true
  }

  func showFindBar() {
    openFindBar(forward: true)
  }

  private func openFindBar(forward: Bool) {
    guard closeState == .open, hasBrowser, !rendererCrashed, isSurfaceVisible else { return }
    if let containerView { containerView.findBar.installEscapeRouting(for: containerView.pageContentView) }
    if findState.isVisible {
      findFieldFocusChanged(true)
      containerView?.findBar.focusAndSelect()
      return
    }
    findGeneration += 1
    findState.isVisible = true
    findState.isSearching = !findState.query.isEmpty
    findState.activeMatch = 0
    findState.matchCount = nil
    updateFindUI()
    bridge?.showFindBar(withQuery: findState.query, forward: forward, generation: findGeneration)
  }

  private func setFindQuery(_ query: String) {
    guard closeState == .open, findState.isVisible else { return }
    let normalized = query.replacingOccurrences(of: "\r", with: "")
    guard normalized != findState.query else { return }
    findState.query = normalized
    findState.activeMatch = 0
    findState.matchCount = nil
    startFind(forward: true)
  }

  private func startFind(forward: Bool) {
    findGeneration += 1
    findState.isSearching = !findState.query.isEmpty
    updateFindUI()
    bridge?.findQuery(findState.query, forward: forward, generation: findGeneration)
  }

  func findNext() { navigateFind(forward: true) }
  func findPrevious() { navigateFind(forward: false) }

  private func navigateFind(forward: Bool) {
    guard closeState == .open, hasBrowser, !rendererCrashed, isSurfaceVisible,
          containerView?.findBar.hasMarkedText != true else { return }
    if !findState.isVisible {
      // ⌘G on a closed bar reuses this tab's query. An empty tab opens an editor.
      openFindBar(forward: forward)
      return
    }
    guard !findState.query.isEmpty else {
      findFieldFocusChanged(true)
      containerView?.findBar.focusAndSelect()
      return
    }
    startFind(forward: forward)
  }

  func closeFindBar() {
    guard findState.isVisible, closeState == .open else { return }
    bridge?.closeFindBar()
  }

  private func findFieldFocusChanged(_ focused: Bool) {
    isEditingFindField = focused
    bridge?.setFindBarFocused(focused)
    if focused {
      wantsPageFocus = false
      bridge?.setFocus(false)
    }
  }

  private func resetFindStateForClose() {
    findGeneration += 1
    findState = BrowserFindState()
    isEditingFindField = false
    restorePageAfterFind = false
    updateFindUI()
    containerView?.findBar.removeEscapeRouting()
  }

  private func emit(_ event: String) {
    AppLog.browser.debug("\(event, privacy: .public)")
    onLifecycleEvent?(event)
  }

  /// Applies a Chromium navigation callback to the published state.
  ///
  /// This is the single place where Chromium state becomes UI state, so the
  /// main-frame URL can never move the text the user is editing: the address
  /// model only mirrors the committed URL while the field is not being edited
  /// (Milestone 2, section 6).
  private func updateNavigationState(
    isLoading: Bool,
    canGoBack: Bool,
    canGoForward: Bool
  ) {
    self.isLoading = isLoading
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    if isLoading {
      didStartLoading = true
      loadStartCount += 1
      loadingProgress = 0
    } else {
      loadingProgress = 1
      if findState.isVisible, findState.isSearching, findState.matchCount == nil {
        startFind(forward: true)
      }
      if didStartLoading, !hasFinishedFirstLoad {
        hasFinishedFirstLoad = true
        emit(
          "browser:first-load-finished(title-present=\(!self.title.isEmpty), url=\(URLLogSanitizer.sanitized(self.url)))"
        )
      }
    }
    onTabMetadataChanged?(self)
  }
}

// MARK: - ChromiumContainerViewDelegate

extension BrowserSession: ChromiumContainerViewDelegate {
  func containerViewDidAddToWindow(_ view: ChromiumContainerView) {
    guard !isClosed else { return }
    createBrowserIfPossible()
  }

  func containerViewDidResize(_ view: ChromiumContainerView) {
    guard !isClosed, view.window != nil else { return }
    bridge?.resize(toBounds: view.pageContentView.bounds)
    bridge?.resizeDevTools()
  }

  func containerViewDidChangeVisibility(_ view: ChromiumContainerView, isVisible: Bool) {
    if isDevToolsOpen, let devToolsWindow {
      if isVisible { devToolsWindow.orderFront(nil) }
      else { devToolsWindow.orderOut(nil) }
    }
    // Hiding a container must not suspend its browser (Milestone 3 section 34):
    // the view stays in the hierarchy and Chromium keeps running. Coming back,
    // the browser is simply told its geometry again so the first frame after the
    // switch matches the container.
    guard !isClosed, isVisible, view.window != nil else { return }
    bridge?.resize(toBounds: view.pageContentView.bounds)
    bridge?.resizeDevTools()
  }
}

// MARK: - BrowserBridgeDelegate

extension BrowserSession: BrowserBridgeDelegate {
  func browserBridge(_ bridge: BrowserBridge, didShowFindBarWithFocus focus: Bool) {
    guard acceptsCallback(from: bridge), closeState == .open else { return }
    findState.isVisible = true
    updateFindUI()
    if focus, isSurfaceVisible {
      findFieldFocusChanged(true)
      containerView?.findBar.focusAndSelect()
    }
  }

  func browserBridgeDidHideFindBar(_ bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge) else { return }
    restorePageAfterFind = findState.isVisible
      && (containerView?.findBar.hasKeyboardFocus == true || holdsAppKitKeyboardFocus)
    findGeneration += 1
    findState.isVisible = false
    findState.isSearching = false
    findState.activeMatch = 0
    findState.matchCount = nil
    isEditingFindField = false
    updateFindUI()
  }

  func browserBridgeRestoreFocus(afterFind bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge) else { return }
    let shouldRestore = restorePageAfterFind
    restorePageAfterFind = false
    if shouldRestore, closeState == .open, isSurfaceVisible,
       containerView?.window?.attachedSheet == nil, !isEditingAddressField {
      focusPage()
    }
  }

  func browserBridgeFindBarHasFocus(_ bridge: BrowserBridge) -> Bool {
    acceptsCallback(from: bridge) && containerView?.findBar.hasKeyboardFocus == true
  }

  func browserBridgeDidInvalidateFindResults(_ bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge) else { return }
    findGeneration += 1
    findState.activeMatch = 0
    findState.matchCount = nil
    findState.isSearching = findState.isVisible && !findState.query.isEmpty
    updateFindUI()
  }

  func browserBridge(_ bridge: BrowserBridge, didFindQuery query: String,
                     generation: Int, requestIdentifier: Int, activeMatch: Int,
                     matchCount: Int, finalUpdate: Bool) {
    guard acceptsCallback(from: bridge), closeState == .open,
          findState.isVisible, !query.isEmpty, query == findState.query,
          generation == findGeneration else { return }
    if matchCount >= 0 { findState.matchCount = matchCount }
    if activeMatch >= 0 { findState.activeMatch = activeMatch }
    if findState.matchCount == 0 { findState.activeMatch = 0 }
    findState.isSearching = !finalUpdate
    updateFindUI()
  }

  func browserBridge(_ bridge: BrowserBridge, didSetInspectedPageBounds bounds: NSRect) {
    guard acceptsCallback(from: bridge) else { return }
    containerView?.setInspectedPageBounds(bounds)
  }

  func browserBridge(_ bridge: BrowserBridge, didSetDevToolsDocked docked: Bool) {
    guard acceptsCallback(from: bridge), closeState == .open,
          let containerView else { return }
    if docked {
      // Chromium's own Inspect Element command can open DevTools directly.
      // Adopt that frontend into the same Cio panel used by our toolbar.
      if !isDevToolsOpen {
        isDevToolsOpen = true
        containerView.showDevToolsPane()
      }
      bridge.reparentDevTools(to: containerView.devToolsHostView)
      devToolsWindow?.orderOut(nil)
      devToolsWindow?.delegate = nil
      devToolsWindow?.close()
      devToolsWindow = nil
    } else {
      if devToolsWindow == nil {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: BrowserLayout.devToolsWindowSize),
          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DevTools — \(title.isEmpty ? "Cio" : title)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        devToolsWindow = window
      }
      if let host = devToolsWindow?.contentView { bridge.reparentDevTools(to: host) }
      if isSurfaceVisible { devToolsWindow?.makeKeyAndOrderFront(nil) }
    }
    containerView.setDevToolsDocked(docked)
  }

  func browserBridgeDidCloseDevTools(_ bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge) else { return }
    isDevToolsOpen = false
    devToolsWindow?.delegate = nil
    devToolsWindow?.close()
    devToolsWindow = nil
    containerView?.hideDevToolsPane()
    if closeState == .open, isSurfaceVisible, !isEditingAddressField, !isEditingFindField { focusPage() }
  }

  func browserBridgeDidCreateBrowser(_ bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge) else { return }
    browserCreationCount += 1
    hasBrowser = true
    rendererCrashed = false
    if let containerView {
      let dark = containerView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      setDarkAppearance(dark)
    }
    emit("browser:created(count=\(browserCreationCount))")
    // Clicking and typing must reach the page without an extra click first
    // (ARCHITECTURE.md section 18). Chromium takes focus from there on - but Chromium
    // creates a browser asynchronously, so by now this tab may already have been
    // hidden again, or the user may have moved the keyboard into the native
    // address field. Taking the keyboard is only correct while this session is
    // still the visible selected surface *and* the keyboard is still meant for
    // page content; otherwise a background or hidden browser would steal AppKit's
    // first responder, which can be made first responder even while hidden.
    if canTakePageFocus {
      bridge.setFocus(true)
    } else {
      AppLog.browser.debug(
        "browser created without taking focus id=\(self.tabID.uuidString, privacy: .public) visible=\(self.containerView?.isSurfaceVisible == true, privacy: .public) wants-page-focus=\(self.wantsPageFocus, privacy: .public)"
      )
    }
    onTabMetadataChanged?(self)
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateTitle title: String) {
    guard acceptsCallback(from: bridge) else { return }
    guard didReceiveMainFrameURL || requestedURL.absoluteString == "about:blank" else { return }
    let title = BrowserPresentationLimits.title(title)
    guard self.title != title else { return }
    self.title = title
    AppLog.navigation.debug("title changed (present=\(!title.isEmpty, privacy: .public))")
    onLifecycleEvent?("navigation:title(present=\(!title.isEmpty))")
    if !lastMainFrameLoadFailed {
      onTitleChanged?(self)
    }
    onTabMetadataChanged?(self)
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateFaviconURLs urls: [String]) {
    guard acceptsCallback(from: bridge) else { return }
    let candidates = urls.compactMap(URL.init(string:)).filter {
      $0.scheme == "https" || $0.scheme == "http"
    }
    guard faviconURLs != candidates else { return }
    faviconURLs = candidates
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateFaviconImage image: NSImage?) {
    guard acceptsCallback(from: bridge) else { return }
    // Retain restored artwork through bootstrap/loading gaps. Once the page
    // finishes, Chromium's current result replaces the cache, including nil.
    guard didReceiveMainFrameURL else { return }
    guard image != nil || (!isLoading && !lastMainFrameLoadFailed) else { return }
    let data = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
      .flatMap { BrowserArtwork.encode($0, as: .favicon) }
    guard faviconData != data || (faviconImage == nil) != (image == nil) else { return }
    faviconData = data
    faviconImage = data.flatMap { BrowserArtwork.decode($0, as: .favicon) }
      .map { NSImage(cgImage: $0, size: .zero) }
    onTabMetadataChanged?(self)
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateURL url: String) {
    guard acceptsCallback(from: bridge) else { return }
    let value = URL(string: url)
    // AddTabAt creates a bootstrap blank document before the requested page.
    // It must not replace a restored URL on disk while that page is loading.
    guard didReceiveMainFrameURL || value?.absoluteString != "about:blank"
      || requestedURL.absoluteString == "about:blank" else { return }
    // Chromium repeats the main-frame URL on several events; only act when it
    // actually changed so the log and the address field stay quiet. The first
    // callback is still meaningful when a restored session was pre-populated
    // with the same URL before Chromium existed: it confirms the live main frame and
    // preserves the Milestone 2 lifecycle event.
    let isFirstMainFrameURL = !didReceiveMainFrameURL
    didReceiveMainFrameURL = true
    guard isFirstMainFrameURL || value != self.url else { return }
    if value != self.url {
      faviconURLs = []
      faviconData = nil
      faviconImage = nil
    }
    self.url = value
    mainFrameURLChangeCount += 1
    addressField.applyBrowserURL(value)
    // The session keeps the complete URL (the address field mirrors it); only
    // the log line and the trace event are redacted.
    let loggedURL = URLLogSanitizer.sanitized(url)
    AppLog.navigation.debug("main-frame URL changed: \(loggedURL, privacy: .public)")
    onLifecycleEvent?("navigation:url(\(loggedURL))")
    onTabMetadataChanged?(self)
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    didUpdateLoadingState isLoading: Bool,
    canGoBack: Bool,
    canGoForward: Bool
  ) {
    guard acceptsCallback(from: bridge) else { return }
    updateNavigationState(
      isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateLoadingProgress progress: Double) {
    guard acceptsCallback(from: bridge) else { return }
    loadingProgress = progress
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    didFailLoadWithError errorText: String,
    errorCode: Int,
    failedURL: String
  ) {
    guard acceptsCallback(from: bridge) else { return }
    lastErrorCode = errorCode
    lastMainFrameLoadFailed = true
    // The error code and text are the diagnostics; the failing URL is written
    // out only through the sanitizer (section 5 of the security fix).
    let loggedURL = URLLogSanitizer.sanitized(failedURL)
    emit(
      "navigation:failed(code=\(errorCode), url=\(loggedURL), text-present=\(!errorText.isEmpty))")
    AppLog.navigation.error(
      "load failed (code=\(errorCode, privacy: .public), text-present=\(!errorText.isEmpty, privacy: .public)) url=\(loggedURL, privacy: .public)"
    )
    if !hasFinishedFirstLoad {
      hasFinishedFirstLoad = true
    }
  }

  func browserBridge(_ bridge: BrowserBridge, didFinishMainFrameLoadWithURL url: String) {
    guard acceptsCallback(from: bridge) else { return }
    guard !lastMainFrameLoadFailed else { return }
    guard let value = URL(string: url), HistoryURLPolicy.isRecordable(value) else { return }
    successfulMainFrameLoadCount += 1
    lastSuccessfulMainFrameURL = value
    onMainFrameLoadFinished?(self, value)
  }

  func browserBridgeDidAcceptClose(_ bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge) else { return }
    notifyCloseAccepted()
  }

  func browserBridgeDidCancelClose(_ bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge), closeState == .userClosePending else { return }
    closeState = .open
    if findState.isVisible, !findState.query.isEmpty { startFind(forward: true) }
    emit("browser:close-cancelled")
    onCloseCancelled?(self)
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    didTerminateRendererWithStatus status: Int,
    errorCode: Int
  ) {
    guard acceptsCallback(from: bridge) else { return }
    rendererCrashed = true
    resetFindStateForClose()
    AppLog.browser.error(
      "renderer terminated (status=\(status, privacy: .public), code=\(errorCode, privacy: .public))")
    emit("renderer:terminated(status=\(status), code=\(errorCode))")
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    destinationPathForDownloadIdentifier downloadIdentifier: Int,
    sourceURL: String,
    suggestedFileName: String,
    cefSuggestedFileName: String,
    contentDisposition: String,
    mimeType: String,
    originalURL: String
  ) -> String {
    guard acceptsCallback(from: bridge) else { return "" }
    guard let value = URL(string: sourceURL), downloadIdentifier >= 0 else { return "" }
    let metadata = DownloadMetadata(
      cefSuggestedFileName: cefSuggestedFileName,
      contentDisposition: contentDisposition,
      mimeType: mimeType,
      originalURL: originalURL.isEmpty ? nil : URL(string: originalURL))
    return onDownloadRequested?(
      self, UInt32(downloadIdentifier), value, suggestedFileName, metadata) ?? ""
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    didUpdateDownloadWithIdentifier downloadIdentifier: Int,
    sourceURL: String,
    suggestedFileName: String,
    cefSuggestedFileName: String,
    contentDisposition: String,
    mimeType: String,
    originalURL: String,
    destinationPath: String,
    receivedBytes: Int64,
    totalBytes: Int64,
    hasTotalBytes: Bool,
    isInProgress: Bool,
    isComplete: Bool,
    isCanceled: Bool,
    isInterrupted: Bool
  ) {
    guard acceptsCallback(from: bridge) else { return }
    guard let value = URL(string: sourceURL), downloadIdentifier >= 0 else { return }
    let update = BrowserDownloadUpdate(
      downloadID: UInt32(downloadIdentifier),
      sourceURL: value,
      suggestedFileName: suggestedFileName,
      metadata: DownloadMetadata(
        cefSuggestedFileName: cefSuggestedFileName,
        contentDisposition: contentDisposition,
        mimeType: mimeType,
        originalURL: originalURL.isEmpty ? nil : URL(string: originalURL)),
      destinationURL: destinationPath.isEmpty ? nil : URL(fileURLWithPath: destinationPath),
      receivedBytes: receivedBytes,
      totalBytes: hasTotalBytes ? totalBytes : nil,
      isInProgress: isInProgress,
      isComplete: isComplete,
      isCancelled: isCanceled,
      isInterrupted: isInterrupted)
    onDownloadUpdated?(self, update)
  }

  /// The native bridge asks whether Chromium may take keyboard focus.
  /// Only the visible selected surface may take it, while page content owns
  /// or is intended to own the keyboard. Background loads and requests while
  /// the native address editor owns focus must not steal it. The historical
  /// source flag is logged for diagnostics; it does not change this policy.
  func browserBridge(_ bridge: BrowserBridge, allowsFocusRequestFromSystem fromSystem: Bool)
    -> Bool
  {
    guard acceptsCallback(from: bridge) else { return false }
    let allowed = !isClosed && isSurfaceVisible && !isEditingAddressField && !isEditingFindField
      && containerView?.window?.attachedSheet == nil && ownsPageKeyboard
    AppLog.browser.debug(
      "focus request id=\(self.tabID.uuidString, privacy: .public) source=\(fromSystem ? "system" : "navigation", privacy: .public) visible=\(self.isSurfaceVisible, privacy: .public) wants-page-focus=\(self.wantsPageFocus, privacy: .public) allowed=\(allowed, privacy: .public)"
    )
    return allowed
  }

  /// Chromium asked for a popup. The bridge already cancelled the unmanaged
  /// native Chromium window; the URL is handed to the runtime owner so it can open as
  /// a managed tab instead (Milestone 3 section 26).
  func browserBridge(_ bridge: BrowserBridge, didRequestNewTabWithURL url: String) {
    guard acceptsCallback(from: bridge) else { return }
    onOpenNewTabRequest?(self, url)
  }

  func browserBridge(_ bridge: BrowserBridge, didRequestExtensionTabWithURL url: String, active: Bool) {
    guard acceptsCallback(from: bridge) else { return }
    onOpenExtensionTabRequest?(self, url, active)
  }

  func browserBridgeDidClose(_ bridge: BrowserBridge) {
    guard acceptsCallback(from: bridge) else { return }
    if closeState == .userClosePending {
      notifyCloseAccepted()
    }
    closeState = .closed
    isClosed = true
    resetFindStateForClose()
    hasBrowser = false
    // Order matters: the diagnostic trace first, then the typed ownership
    // callback the manager releases this session from.
    emit("browser:closed")
    onClosed?(self)
  }

  private func notifyCloseAccepted() {
    guard !isClosed, closeState != .accepted else { return }
    closeState = .accepted
    emit("browser:close-accepted")
    onCloseAccepted?(self)
  }

  /// Chromium can deliver queued callbacks after a browser has started closing. The
  /// bridge identity and the session's closed bit together reject callbacks
  /// from a stale runtime before they can mutate navigation, focus, history or
  /// download state.
  private func acceptsCallback(from bridge: BrowserBridge) -> Bool {
    !isClosed && self.bridge === bridge
  }
}

// Closing the detached inspector follows the same asynchronous Chromium teardown as
// the frontend's Close button and the application menu shortcut.
extension BrowserSession: NSWindowDelegate {
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === devToolsWindow else { return true }
    bridge?.closeDevTools()
    return false
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === devToolsWindow else { return }
    bridge?.resizeDevTools()
  }
}

// Protocol projections retain the original session, editor and @Published streams.
extension BrowserSession: BrowserSessionProtocol {
  var extensionActionsPublisher: AnyPublisher<[BrowserExtensionAction], Never> { $extensionActions.eraseToAnyPublisher() }
  var engineAddressField: any BrowserAddressEditing { addressField }
  var canGoBackPublisher: AnyPublisher<Bool, Never> { $canGoBack.eraseToAnyPublisher() }
  var canGoForwardPublisher: AnyPublisher<Bool, Never> { $canGoForward.eraseToAnyPublisher() }
  var urlPublisher: AnyPublisher<URL?, Never> { $url.eraseToAnyPublisher() }
  var isLoadingPublisher: AnyPublisher<Bool, Never> { $isLoading.eraseToAnyPublisher() }
  var lastErrorCodePublisher: AnyPublisher<Int?, Never> { $lastErrorCode.eraseToAnyPublisher() }
  var rendererCrashedPublisher: AnyPublisher<Bool, Never> { $rendererCrashed.eraseToAnyPublisher() }
  var hasFinishedFirstLoadPublisher: AnyPublisher<Bool, Never> { $hasFinishedFirstLoad.eraseToAnyPublisher() }
}
