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

import AppKit
import Foundation

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

  /// Lifecycle milestones, for logging and the verification tooling.
  var onLifecycleEvent: ((String) -> Void)?

  private var bridge: BrowserBridge?
  private weak var containerView: ChromiumContainerView?
  private var didStartLoading = false

  init(initialURL: URL) {
    self.initialURL = initialURL
    super.init()
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
    bridge?.loadURL(url.absoluteString)
  }

  func goBack() {
    bridge?.goBack()
  }

  func goForward() {
    bridge?.goForward()
  }

  func reload() {
    bridge?.reload()
  }

  func stop() {
    bridge?.stopLoading()
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

  private func emit(_ event: String) {
    AppLog.browser.debug("\(event, privacy: .public)")
    onLifecycleEvent?(event)
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
    hasBrowser = true
    containerView?.setBrowserAttached(true)
    emit("browser:created")
    // Clicking and typing must reach the page without an extra click first
    // (ARCHITECTURE.md section 18). CEF takes focus from there on.
    bridge.setFocus(true)
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateTitle title: String) {
    self.title = title
  }

  func browserBridge(_ bridge: BrowserBridge, didUpdateURL url: String) {
    self.url = URL(string: url)
  }

  func browserBridge(
    _ bridge: BrowserBridge,
    didUpdateLoadingState isLoading: Bool,
    canGoBack: Bool,
    canGoForward: Bool
  ) {
    self.isLoading = isLoading
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    if isLoading {
      didStartLoading = true
      loadingProgress = 0
    } else {
      loadingProgress = 1
      if didStartLoading, !hasFinishedFirstLoad {
        hasFinishedFirstLoad = true
        emit("browser:first-load-finished(title=\(self.title), url=\(self.url?.absoluteString ?? ""))")
      }
    }
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
