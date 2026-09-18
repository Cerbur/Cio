//
//  BrowserSession.swift
//  NativeBrowser
//
//  Runtime-only browser session: one Chromium browser instance for one tab
//  (ARCHITECTURE.md section 7).
//
//  Deliberately not Codable and never persisted: the persisted domain model is
//  a separate type that arrives with tabs in Milestone 3 (section 6).
//
//  This class owns no CEF type: everything goes through BrowserBridge.
//
//  Milestone 2 adds the UI-facing navigation state (section 20 of
//  ARCHITECTURE.md) and the address-field editing state. The editing flag lives
//  on the session on purpose: the "do not overwrite what the user is typing"
//  rule is stated once, in BrowserSession.updateNavigationState, instead of
//  being split between the toolbar and the bridge.
//

import AppKit
import Foundation

/// A snapshot of everything the navigation UI needs (ARCHITECTURE.md section
/// 20). Produced from the CEF callbacks; never derived from a Swift-side
/// history counter.
struct NavigationState: Equatable {
  /// URL of the main frame.
  var url: URL?
  var title = ""

  var isLoading = false
  /// 0...1 while loading; `nil` when Chromium has not reported a value.
  var loadingProgress: Double?

  var canGoBack = false
  var canGoForward = false
}

@MainActor
final class BrowserSession: NSObject, ObservableObject, Identifiable {
  let id = UUID()

  /// URL the session opens when its browser is first created.
  let initialURL: URL

  @Published private(set) var title = ""
  @Published private(set) var url: URL?
  @Published private(set) var isLoading = false
  @Published private(set) var loadingProgress: Double = 0
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  @Published private(set) var lastErrorCode: Int?

  /// True once the Chromium browser object exists.
  @Published private(set) var hasBrowser = false
  /// True once Chromium destroyed the browser; the session cannot be reused.
  private(set) var isClosed = false
  /// True after the first load finished (successfully or not).
  private(set) var hasFinishedFirstLoad = false

  /// How many Chromium browsers this session has created. Must stay at 1 for a
  /// session's lifetime: navigation, resizing and SwiftUI re-renders must never
  /// build a second browser (Milestone 2, section 20).
  private(set) var browserCreationCount = 0

  /// Incremented every time Chromium reports a different main-frame URL. Used
  /// by the integration self-test to prove that a navigation actually happened
  /// rather than merely finishing a cached load before it could be observed.
  private(set) var mainFrameURLChangeCount = 0

  /// Incremented every time Chromium starts loading. A reload does not change
  /// the main-frame URL, so this is what proves that a reload reached Chromium.
  private(set) var loadStartCount = 0

  /// Editing state of the native address field.
  let addressField = AddressFieldModel()

  /// True while the native address field owns the keyboard. Used to keep the
  /// toolbar's focus handling from fighting Chromium for first responder.
  private(set) var isEditingAddressField = false

  /// Lifecycle milestones, for logging and the verification tooling.
  var onLifecycleEvent: ((String) -> Void)?

  private var bridge: BrowserBridge?
  private weak var containerView: ChromiumContainerView?
  private var didStartLoading = false

  init(initialURL: URL) {
    self.initialURL = initialURL
    super.init()
  }

  // MARK: - Navigation state

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

  // MARK: - View attachment

  /// Binds the session to the AppKit container that will host the Chromium
  /// view. The browser itself is created once the container is in a window.
  func attach(to view: ChromiumContainerView) {
    if containerView === view {
      return
    }
    if let existing = containerView, existing !== view, bridge != nil {
      // SwiftUI re-created the representable's view: move the existing browser
      // instead of creating a second one (section 28).
      containerView = view
      view.delegate = self
      bridge?.reparent(to: view)
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
    let bridge = BrowserBridge(parentView: view)
    bridge.delegate = self
    self.bridge = bridge
    bridge.loadURL(initialURL.absoluteString)
  }

  // MARK: - Navigation

  func load(_ url: URL) {
    guard !isClosed else { return }
    AppLog.navigation.info("load \(url.absoluteString, privacy: .public)")
    onLifecycleEvent?("navigation:load(\(url.absoluteString))")
    bridge?.loadURL(url.absoluteString)
  }

  func goBack() {
    guard canGoBack else {
      AppLog.navigation.debug("back ignored: no history entry")
      return
    }
    AppLog.navigation.info("back")
    onLifecycleEvent?("navigation:back")
    bridge?.goBack()
  }

  func goForward() {
    guard canGoForward else {
      AppLog.navigation.debug("forward ignored: no forward entry")
      return
    }
    AppLog.navigation.info("forward")
    onLifecycleEvent?("navigation:forward")
    bridge?.goForward()
  }

  func reload() {
    AppLog.navigation.info("reload")
    onLifecycleEvent?("navigation:reload")
    bridge?.reload()
  }

  func stop() {
    AppLog.navigation.info("stop")
    onLifecycleEvent?("navigation:stop")
    bridge?.stopLoading()
  }

  /// Reload when the page is idle, stop when it is loading (Milestone 2,
  /// section 11). The decision comes from CEF's loading state, never from a
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

  func blur() {
    bridge?.setFocus(false)
  }

  /// Requests browser destruction. Safe to call more than once.
  func close() {
    guard !isClosed else { return }
    guard let bridge else {
      isClosed = true
      onLifecycleEvent?("browser:closed(before-creation)")
      return
    }
    bridge.close()
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
      blur()
    } else {
      addressField.endEditing()
    }
  }

  /// Returns the keyboard to Chromium.
  ///
  /// The main-queue hop matters: this is normally called from a control action
  /// while AppKit is still completing its own focus change, and a re-entrant
  /// first-responder change is ignored. One hop lets that settle; it is the
  /// native way to defer to the end of the event, not a delay.
  func focusPage() {
    if let view = containerView {
      view.window?.makeFirstResponder(view)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isClosed else { return }
      self.focus()
    }
  }

  private func emit(_ event: String) {
    AppLog.browser.debug("\(event, privacy: .public)")
    onLifecycleEvent?(event)
  }

  /// Applies a Chromium navigation callback to the published state.
  ///
  /// This is the single place where CEF state becomes UI state, so the
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
      if didStartLoading, !hasFinishedFirstLoad {
        hasFinishedFirstLoad = true
        emit("browser:first-load-finished(title=\(self.title), url=\(self.url?.absoluteString ?? ""))")
      }
    }
  }
}

// MARK: - ChromiumContainerViewDelegate

extension BrowserSession: ChromiumContainerViewDelegate {
  func containerViewDidMoveToWindow(_ view: ChromiumContainerView) {
    createBrowserIfPossible()
  }

  func containerViewDidResize(_ view: ChromiumContainerView) {
    guard view.window != nil else { return }
    bridge?.resize(toBounds: view.bounds)
  }
}

// MARK: - BrowserBridgeDelegate

extension BrowserSession: BrowserBridgeDelegate {
  func browserBridgeDidCreateBrowser(_ bridge: BrowserBridge) {
    browserCreationCount += 1
    hasBrowser = true
    containerView?.setBrowserAttached(true)
    emit("browser:created(count=\(browserCreationCount))")
    // Clicking and typing must reach the page without an extra click first
    // (ARCHITECTURE.md section 18). CEF takes focus from there on.
    bridge.setFocus(true)
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateTitle title: String) {
    guard self.title != title else { return }
    self.title = title
    AppLog.navigation.debug("title changed: \(title, privacy: .public)")
    onLifecycleEvent?("navigation:title(\(title))")
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateURL url: String) {
    let value = URL(string: url)
    // Chromium repeats the main-frame URL on several events; only act when it
    // actually changed so the log and the address field stay quiet.
    guard value != self.url else { return }
    self.url = value
    mainFrameURLChangeCount += 1
    addressField.applyBrowserURL(value)
    AppLog.navigation.debug("main-frame URL changed: \(url, privacy: .public)")
    onLifecycleEvent?("navigation:url(\(url))")
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    didUpdateLoadingState isLoading: Bool,
    canGoBack: Bool,
    canGoForward: Bool
  ) {
    updateNavigationState(
      isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateLoadingProgress progress: Double) {
    loadingProgress = progress
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    didFailLoadWithError errorText: String,
    errorCode: Int,
    failedURL: String
  ) {
    lastErrorCode = errorCode
    emit("navigation:failed(code=\(errorCode), url=\(failedURL), text=\(errorText))")
    AppLog.navigation.error(
      "load failed: \(errorText, privacy: .public) (\(errorCode, privacy: .public)) for \(failedURL, privacy: .public)"
    )
    if !hasFinishedFirstLoad {
      hasFinishedFirstLoad = true
    }
  }

  func browserBridgeDidClose(_ bridge: BrowserBridge) {
    guard !isClosed else { return }
    isClosed = true
    hasBrowser = false
    emit("browser:closed")
  }
}
