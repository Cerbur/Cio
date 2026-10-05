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
  nonisolated(unsafe) private var splitRevealDisplayLink: CADisplayLink?
  private var splitRevealGlassFrames: [CGRect] = []
  private var splitRevealGlassRadii: [CGFloat] = []
  private var splitRevealGlassBeginTime: CFTimeInterval = 0
  private var splitRevealGlassDuration: TimeInterval = 0
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
              toolbarVisible: Bool, toolbarLayoutFrame: CGRect, animatedVisibility: Bool) {
    viewport.isHidden = false
    if viewport.frame != frame { viewport.frame = frame }
    // Assign the final render size once. Split motion happens on the shared
    // viewport layer, never by repeatedly resizing Chromium during a flight.
    if surface.frame != viewport.bounds { surface.frame = viewport.bounds }
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
  var splitGlassOpacity: Float {
    guard let glass = splitRevealGlass, !glass.isHidden, let layer = glass.layer else { return 0 }
    return (layer.presentation() ?? layer).opacity
  }

  func beginSplitRevealGlass(at beginTime: CFTimeInterval, frames: [CGRect], radii: [CGFloat],
                            direction: BrowserSplitRevealTransition.Direction,
                            fromOpacity: Float, toOpacity: Float) {
    guard let frame = frames.first, let radius = radii.first else { return }
    splitRevealDisplayLink?.invalidate()
    // Reuse the native material on reversal; rebuilding its effect tree at the
    // precise handoff can make an otherwise continuous page animation hitch.
    let glass: SplitRevealGlassView
    if let existing = splitRevealGlass {
      glass = existing
    } else {
      glass = SplitRevealGlassView(frame: frame)
      glass.style = .regular
      glass.wantsLayer = true
      glass.setAccessibilityElement(false)
      viewport.addSubview(glass, positioned: .above, relativeTo: surface)
      splitRevealGlass = glass
    }
    glass.frame = frame
    glass.cornerRadius = radius
    glass.isHidden = false
    splitRevealGlassFrames = frames
    splitRevealGlassRadii = radii
    splitRevealGlassBeginTime = beginTime
    splitRevealGlassDuration = direction.duration
    guard let layer = glass.layer else { return }
    layer.opacity = toOpacity
    let fade = BrowserSplitRevealTransition.glassOpacityAnimation(direction, from: fromOpacity, to: toOpacity)
    fade.beginTime = beginTime
    layer.add(fade, forKey: "split-reveal-glass-fade")
    let target = SplitRevealDisplayLinkTarget(page: self)
    let displayLink = viewport.displayLink(target: target, selector: #selector(SplitRevealDisplayLinkTarget.update(_:)))
    splitRevealDisplayLink = displayLink
    displayLink.add(to: .main, forMode: .common)
  }

  fileprivate func updateSplitRevealGlass(_ displayLink: CADisplayLink) {
    guard let glass = splitRevealGlass, !glass.isHidden,
          splitRevealGlassFrames.count > 1 else { return }
    // A Timer samples the previous compositor frame and can run multiple times
    // between refreshes. Target the upcoming refresh using the parent's exact
    // wall-clock geometry samples, keeping the native rim with its outline.
    let amount = min(1, max(0, (displayLink.targetTimestamp - splitRevealGlassBeginTime) / splitRevealGlassDuration))
    let position = amount * Double(splitRevealGlassFrames.count - 1)
    let index = min(splitRevealGlassFrames.count - 2, Int(position))
    let fraction = CGFloat(position - Double(index))
    let a = splitRevealGlassFrames[index]
    let b = splitRevealGlassFrames[index + 1]
    func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fraction }
    let frame = CGRect(x: blend(a.minX, b.minX), y: blend(a.minY, b.minY),
                       width: blend(a.width, b.width), height: blend(a.height, b.height))
    let radius = blend(splitRevealGlassRadii[index], splitRevealGlassRadii[index + 1])
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if glass.frame != frame { glass.frame = frame }
    if glass.cornerRadius != radius { glass.cornerRadius = radius }
    // Let AppKit coalesce material layout with its normal display pass. Forcing
    // layoutSubtreeIfNeeded on every tick competes with Chromium for the frame.
    CATransaction.commit()
  }

  func endSplitRevealGlass() {
    splitRevealDisplayLink?.invalidate()
    splitRevealDisplayLink = nil
    splitRevealGlassFrames = []
    splitRevealGlassRadii = []
    splitRevealGlass?.layer?.removeAnimation(forKey: "split-reveal-glass-fade")
    splitRevealGlass?.isHidden = true
  }

  deinit { splitRevealDisplayLink?.invalidate() }

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

/// CADisplayLink retains its target; a weak forwarding target keeps page
/// retirement independent of the display callback's lifetime.
@MainActor
private final class SplitRevealDisplayLinkTarget: NSObject {
  weak var page: BrowserPagePresentation?
  init(page: BrowserPagePresentation) { self.page = page }
  @objc func update(_ displayLink: CADisplayLink) { page?.updateSplitRevealGlass(displayLink) }
}
