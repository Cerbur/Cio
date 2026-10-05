import AppKit

/// A stable page UI module: one tab-bound toolbar and one Chromium surface.
/// Single-page, split and preview layouts all refer to the same instance. The
/// splitter host supplies and clips the viewport; the toolbar/editor mount in
/// the shell overlay so expanded address panels remain outside content clipping.
@MainActor
final class BrowserPagePresentation {
  let tabID: UUID
  let surface: ChromiumContainerView
  let viewport: NSView
  private(set) var toolbar: BrowserToolbarController?
  let splitControl = BrowserSplitPaneControl(frame: .zero)
  private var splitRevealGlass: SplitRevealGlassView?
  nonisolated(unsafe) private var splitRevealGlassTimer: Timer?
  private weak var installedWindow: NSWindow?

  init(tabID: UUID, surface: ChromiumContainerView, viewport: NSView) {
    self.tabID = tabID
    self.surface = surface
    self.viewport = viewport
    surface.autoresizingMask = []
    splitControl.dragSource = { [weak viewport] in
      guard let viewport else { return (.zero, nil) }
      var image: NSImage?
      if let bitmap = viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds) {
        viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
        let snapshot = NSImage(size: viewport.bounds.size)
        snapshot.addRepresentation(bitmap)
        image = snapshot
      }
      return (viewport.convert(viewport.bounds, to: nil), image)
    }
    surface.setFrameOrigin(.zero)
    viewport.addSubview(surface)
  }

  /// Bare runtime hosts can mount Chromium without UI dependencies. Production
  /// configures the toolbar once, retaining it for the lifetime of this page.
  func configureToolbar(workspace: BrowserWorkspaceStore, history: HistoryService) {
    guard toolbar == nil else { return }
    let id = tabID
    splitControl.onClose = { [weak workspace] in workspace?.closeTab(id: id) }
    splitControl.onMinimize = { [weak workspace] in workspace?.detachSplitPane(id) }
    splitControl.onExpand = { [weak workspace] in workspace?.detachSplitPane(id, selectDetached: true) }
    let toolbar = BrowserToolbarController(workspace: workspace, history: history,
      browserView: viewport, tabID: tabID, initiallyVisible: false)
    self.toolbar = toolbar
    splitControl.addressFrameProvider = { [weak toolbar] in toolbar?.addressCapsuleFrame(in: nil) }
    toolbar.onAddressCapsuleLayout = { [weak control = splitControl] in control?.addressLayoutDidChange() }
  }

  func layout(in contentHost: NSView, chromeHost: NSView?, frame: CGRect,
              cropOnly: Bool, toolbarVisible: Bool, toolbarLayoutFrame: CGRect, animatedVisibility: Bool) {
    viewport.isHidden = false
    if viewport.frame != frame { viewport.frame = frame }
    // Preview only resizes the outer crop. Chromium receives its committed
    // viewport size after the transition settles, or immediately for divider drags.
    if !cropOnly, surface.frame != viewport.bounds { surface.frame = viewport.bounds }
    guard let toolbar else { return }
    guard toolbarVisible else {
      // Keep outgoing chrome and its independent address overlay at their last
      // visible position while the outer content container collapses/moves.
      toolbar.setPageControlsVisible(false, animated: animatedVisibility)
      return
    }
    guard let chromeHost, let window = contentHost.window else { return }
    if toolbar.view.superview !== chromeHost {
      chromeHost.addSubview(toolbar.view, positioned: .above, relativeTo: nil)
    }
    let toolbarFrame = contentHost.convert(CGRect(x: toolbarLayoutFrame.minX, y: -BrowserLayout.chromeThickness,
      width: toolbarLayoutFrame.width, height: BrowserLayout.chromeThickness), to: chromeHost)
    if toolbar.view.frame != toolbarFrame { toolbar.view.frame = toolbarFrame }
    if installedWindow !== window {
      installedWindow = window
      toolbar.install(in: window)
    }
    toolbar.setPageControlsVisible(toolbarVisible, animated: animatedVisibility)
    toolbar.browserGeometryDidChange()
  }

  func hide(animated: Bool) {
    viewport.isHidden = true
    splitControl.isHidden = true
    splitControl.collapse()
    toolbar?.setPageControlsVisible(false, animated: animated)
  }

  /// Chromium stays mounted at its target size. The glass is a sibling inside
  /// the same viewport, so the parent's transform and mask affect both together.
  func beginSplitRevealGlass(at beginTime: CFTimeInterval, crop: CGRect, scale: CGFloat) {
    endSplitRevealGlass()
    let glass = SplitRevealGlassView(frame: crop)
    glass.style = .regular
    glass.cornerRadius = BrowserLayout.contentCornerRadius / scale
    glass.wantsLayer = true
    glass.setAccessibilityElement(false)
    viewport.addSubview(glass, positioned: .above, relativeTo: surface)
    splitRevealGlass = glass
    guard let layer = glass.layer else { return }
    layer.opacity = 0
    let fade = CAKeyframeAnimation(keyPath: "opacity")
    fade.values = [1, 1, 0.85, 0.4, 0]
    fade.keyTimes = [0, 0.15, 0.4, 0.75, 1]
    fade.beginTime = beginTime
    fade.duration = BrowserSplitRevealTransition.glassFadeDuration
    fade.timingFunction = BrowserSplitRevealTransition.glassFadeTimingFunction
    layer.add(fade, forKey: "split-reveal-glass-fade")
    // A full-size material clipped by a smaller outline loses its native rim.
    // Track the shared parent's *presentation* crop for the glass shape only;
    // Chromium's layout and the compositor transform remain untouched.
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let glass = self.splitRevealGlass,
              let parent = self.viewport.layer?.presentation(),
              let mask = parent.mask as? CAShapeLayer,
              let crop = mask.path?.boundingBoxOfPath else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = crop
        glass.cornerRadius = BrowserLayout.contentCornerRadius / max(0.001, parent.transform.m11)
        glass.layoutSubtreeIfNeeded()
        CATransaction.commit()
      }
    }
    splitRevealGlassTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func endSplitRevealGlass() {
    splitRevealGlassTimer?.invalidate()
    splitRevealGlassTimer = nil
    splitRevealGlass?.removeFromSuperview()
    splitRevealGlass = nil
  }

  deinit { splitRevealGlassTimer?.invalidate() }

  func dispose() {
    endSplitRevealGlass()
    toolbar?.dispose()
    splitControl.removeFromSuperview()
    viewport.removeFromSuperview()
  }
}

/// The transition material never intercepts Chromium's native input.
private final class SplitRevealGlassView: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
