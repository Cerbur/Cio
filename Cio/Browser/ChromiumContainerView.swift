//
//  ChromiumContainerView.swift
//  Cio
//
//  AppKit container that hosts one Chromium browser view (ARCHITECTURE.md section 9).
//  Chromium supplies page/inspector geometry to stable native child hosts;
//  BrowserSession owns the browser and detached inspector window lifetimes.
//
//  Milestone 3: the container is created and destroyed by
//  BrowserSessionManager, one per live BrowserSession, and a tab switch only
//  changes -isHidden. The container is never removed from the hierarchy while
//  its session is alive, because removing it would deallocate the Chromium host view
//  and therefore destroy the WebContents (Milestone 3 section 11).
//

import CioUI
import CioEngine
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

/// Chromium's AdvancedApp owns the splitter, device toolbar and responsive
/// viewport. Its inspected-page placeholder is covered by our stable page host.
/// The real page continues receiving native input and rendering through Chromium.
final class ChromiumContainerView: NSView {
  weak var delegate: ChromiumContainerViewDelegate?
  let pageContentView = NSView()
  let devToolsHostView = NSView()
  let devToolsEmulationHostView = NSView()
  let findBar = BrowserFindBarView(frame: .zero)
  private var inspectedPageBounds: CGRect?
  private(set) var isDevToolsVisible = false
  private(set) var isSurfaceVisible = true

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // Expose the whole native surface as a selectable ancestor for screenshot
    // tools that inspect accessibility elements. AppKit supplies its live screen
    // frame; keep Chromium's descendants and native hit testing intact so page
    // controls remain accessible. The screenshot tool chooses the selection level.
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    wantsLayer = true
    for host in [devToolsHostView, devToolsEmulationHostView, pageContentView] {
      host.frame = bounds
      addSubview(host)
    }
    devToolsHostView.isHidden = true
    devToolsEmulationHostView.isHidden = true
    addSubview(findBar, positioned: .above, relativeTo: nil)
    findBar.installEscapeRouting(for: pageContentView)
    updateBackgroundColor()
    ApplicationRuntime.shared.record("appkit:chromium-container-created")
    AppLog.browser.debug("ChromiumContainerView created")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func accessibilityLabel() -> String? {
    let title = browserSession?.title ?? ""
    return title.isEmpty ? "Web content" : "Web content: \(title)"
  }

  override func accessibilityIdentifier() -> String {
    guard let tabID = browserSession?.tabID else { return "chromium-container" }
    return "chromium-container-\(tabID.uuidString)"
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
    // Keep the page intact while Chromium loads the frontend and resolves its
    // saved dock side. Only its real placeholder bounds may reserve space.
    inspectedPageBounds = nil
    devToolsHostView.isHidden = false
    layoutPanes()
  }

  /// Called only after Chromium released both inspector and toolbox children.
  func hideDevToolsPane() {
    isDevToolsVisible = false
    inspectedPageBounds = nil
    devToolsHostView.isHidden = true
    devToolsEmulationHostView.isHidden = true
    layoutPanes()
  }

  func setDevToolsDocked(_ docked: Bool) {
    devToolsHostView.isHidden = !docked
    devToolsEmulationHostView.isHidden = docked
    if !docked { inspectedPageBounds = bounds }
    layoutPanes()
  }

  func setInspectedPageBounds(_ rect: CGRect) {
    guard isDevToolsVisible, rect.origin.x.isFinite, rect.origin.y.isFinite,
          rect.width.isFinite, rect.height.isFinite,
          inspectedPageBounds != rect else { return }
    inspectedPageBounds = rect
    layoutPanes()
  }

  override func layout() {
    super.layout()
    layoutPanes()
  }

  private func layoutPanes() {
    devToolsHostView.frame = bounds
    devToolsEmulationHostView.frame = bounds
    let rect = isDevToolsVisible ? (inspectedPageBounds ?? bounds).intersection(bounds) : bounds
    pageContentView.frame = rect.isNull ? .zero : rect
    let pageBounds = pageContentView.frame
    let findWidth = max(0, min(366, pageBounds.width - 12))
    findBar.frame = CGRect(x: pageBounds.maxX - findWidth - 6, y: pageBounds.minY + 6,
      width: findWidth, height: BrowserFindBarView.height(for: findWidth))
    delegate?.containerViewDidResize(self)
  }

  /// Shows or hides this container as the selected tab surface.
  ///
  /// Hiding is exactly that - a hide. The view stays a subview of the surface
  /// host inside its stable page viewport, so the Chromium view it hosts is not
  /// deallocated and switching back
  /// does not create a second WebContents.
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
    layoutPanes()
  }

  deinit {
    AppLog.browser.debug("ChromiumContainerView released")
  }
}

// Native UI consumes the original view and weak session delegate.
extension ChromiumContainerView: BrowserNativeSurface {
  var nativeView: NSView { self }
  var browserSession: (any BrowserSessionProtocol)? { delegate as? any BrowserSessionProtocol }
}
