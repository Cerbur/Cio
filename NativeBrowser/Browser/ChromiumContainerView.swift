//
//  ChromiumContainerView.swift
//  NativeBrowser
//
//  AppKit container that hosts one CEF browser view (ARCHITECTURE.md section 9).
//  It owns page/inspector geometry: CEF renders into stable child hosts inside
//  a native NSSplitView, and BrowserSession owns both browser lifetimes.
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

final class ChromiumContainerView: NSView, NSSplitViewDelegate {
  weak var delegate: ChromiumContainerViewDelegate?

  /// Stable native parents; opening the inspector never reparents the page.
  let pageContentView = NSView()
  let devToolsHostView = NSView()
  private let splitView = ChromiumPageSplitView()
  private var devToolsFraction = BrowserLayout.devToolsDefaultFraction
  private var isUpdatingLayout = false
  private(set) var isDevToolsVisible = false

  /// Whether this container is the selected tab's surface. Hidden containers
  /// keep their browser alive; they simply do not draw.
  private(set) var isSurfaceVisible = true

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    splitView.frame = bounds
    splitView.autoresizingMask = [.width, .height]
    splitView.isVertical = false
    splitView.dividerStyle = .thin
    splitView.delegate = self
    splitView.addArrangedSubview(pageContentView)
    addSubview(splitView)
    pageContentView.frame = splitView.bounds
    splitView.setAccessibilityLabel("Page and Web Inspector")
    updateBackgroundColor()
    ApplicationRuntime.shared.record("appkit:chromium-container-created")
    AppLog.browser.debug("ChromiumContainerView created")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }
  }

  func showDevToolsPane() {
    guard !isDevToolsVisible else { return }
    isDevToolsVisible = true
    isUpdatingLayout = true
    splitView.addArrangedSubview(devToolsHostView)
    isUpdatingLayout = false
    layoutPanes()
  }

  /// Called only after Chromium released the inspector's child view.
  func hideDevToolsPane() {
    guard isDevToolsVisible else { return }
    isUpdatingLayout = true
    isDevToolsVisible = false
    splitView.removeArrangedSubview(devToolsHostView)
    devToolsHostView.removeFromSuperview()
    isUpdatingLayout = false
    layoutPanes()
  }

  private var availablePaneHeight: CGFloat {
    max(0, splitView.bounds.height - splitView.dividerThickness)
  }

  private var minimumPageHeight: CGFloat {
    min(BrowserLayout.inspectedPageMinimumHeight, availablePaneHeight * 0.4)
  }

  private var minimumDevToolsHeight: CGFloat {
    min(BrowserLayout.devToolsMinimumHeight, availablePaneHeight * 0.4)
  }

  private func layoutPanes() {
    guard !isUpdatingLayout else { return }
    isUpdatingLayout = true
    if isDevToolsVisible {
      let height = availablePaneHeight
      let inspectorHeight = min(max(height * devToolsFraction, minimumDevToolsHeight),
                                height - minimumPageHeight)
      let pageHeight = height - inspectorHeight
      pageContentView.frame = CGRect(x: 0, y: 0, width: splitView.bounds.width, height: pageHeight)
      devToolsHostView.frame = CGRect(x: 0, y: pageHeight + splitView.dividerThickness,
        width: splitView.bounds.width, height: inspectorHeight)
    } else {
      pageContentView.frame = splitView.bounds
    }
    isUpdatingLayout = false
    delegate?.containerViewDidResize(self)
  }

  func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
    layoutPanes()
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard !isUpdatingLayout else { return }
    if isDevToolsVisible, availablePaneHeight > 0 {
      devToolsFraction = devToolsHostView.frame.height / availablePaneHeight
    }
    delegate?.containerViewDidResize(self)
  }

  func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

  func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                 ofSubviewAt dividerIndex: Int) -> CGFloat {
    minimumPageHeight
  }

  func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                 ofSubviewAt dividerIndex: Int) -> CGFloat {
    availablePaneHeight - minimumDevToolsHeight
  }

  /// Shows or hides this container as the selected tab surface.
  ///
  /// Hiding is exactly that - a hide. The view stays a subview of the surface
  /// host inside its stable page viewport, so the Chromium view it hosts is not
  /// deallocated and switching back
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
    let changed = frame.size != newSize
    super.setFrameSize(newSize)
    guard changed else { return }
    delegate?.containerViewDidResize(self)
  }

  deinit {
    AppLog.browser.debug("ChromiumContainerView released")
  }
}

/// NSSplitView handles dragging, cursor feedback and accessibility. A flipped
/// coordinate system places its first (page) pane above the inspector.
private final class ChromiumPageSplitView: NSSplitView {
  override var isFlipped: Bool { true }
}
