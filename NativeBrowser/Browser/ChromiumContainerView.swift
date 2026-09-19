//
//  ChromiumContainerView.swift
//  NativeBrowser
//
//  AppKit container that hosts one CEF browser view (ARCHITECTURE.md section 9).
//  It owns nothing but geometry: the Chromium browser view is added by CEF as a
//  child of this view, and BrowserSession reacts to the AppKit callbacks below.
//
//  Milestone 3: the container is created and destroyed by
//  BrowserSessionManager, one per live BrowserSession, and a tab switch only
//  changes -isHidden. The container is never removed from the hierarchy while
//  its session is alive, because removing it would deallocate the CEF host view
//  and therefore destroy the CefBrowser (Milestone 3 section 11).
//

import AppKit

@MainActor
protocol ChromiumContainerViewDelegate: AnyObject {
  /// The view was added to (or removed from) a window.
  func containerViewDidAddToWindow(_ view: ChromiumContainerView)
  /// The view changed size; the browser must be told about it.
  func containerViewDidResize(_ view: ChromiumContainerView)
  /// The container became, or stopped being, the visible tab surface.
  func containerViewDidChangeVisibility(_ view: ChromiumContainerView, isVisible: Bool)
}

final class ChromiumContainerView: NSView {
  weak var delegate: ChromiumContainerViewDelegate?

  /// Whether this container is the selected tab's surface. Hidden containers
  /// keep their browser alive; they simply do not draw.
  private(set) var isSurfaceVisible = true

  private let placeholderLabel: NSTextField = {
    let label = NSTextField(labelWithString: "Chromium browser view")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.alignment = .center
    label.textColor = .tertiaryLabelColor
    label.font = .systemFont(ofSize: 13)
    return label
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    addSubview(placeholderLabel)
    NSLayoutConstraint.activate([
      placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    ApplicationRuntime.shared.record("appkit:chromium-container-created")
    AppLog.browser.debug("ChromiumContainerView created")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Hides the placeholder once Chromium has attached its own view.
  func setBrowserAttached(_ attached: Bool) {
    placeholderLabel.isHidden = attached
  }

  /// Shows or hides this container as the selected tab surface.
  ///
  /// Hiding is exactly that - a hide. The view stays a subview of the surface
  /// host, so the Chromium view it hosts is not deallocated and switching back
  /// does not create a second CefBrowser.
  func setSurfaceVisible(_ visible: Bool) {
    guard isSurfaceVisible != visible else { return }
    isSurfaceVisible = visible
    isHidden = !visible
    delegate?.containerViewDidChangeVisibility(self, isVisible: visible)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    delegate?.containerViewDidAddToWindow(self)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    delegate?.containerViewDidResize(self)
  }

  deinit {
    AppLog.browser.debug("ChromiumContainerView released")
  }
}
