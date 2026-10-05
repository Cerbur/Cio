import AppKit
import Combine

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
  private var splitRevealLoadObservation: AnyCancellable?
  private var splitRevealContentFadeToken: UUID?
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
    endSplitRevealGlass()
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

  func beginSplitRevealGlass(direction: BrowserSplitRevealTransition.Direction,
                            fromOpacity: Float, toOpacity: Float) {
    // Reuse the native material on reversal; rebuilding its effect tree at the
    // precise handoff can make an otherwise continuous page animation hitch.
    let glass: SplitRevealGlassView
    if let existing = splitRevealGlass {
      glass = existing
    } else {
      glass = SplitRevealGlassView(frame: viewport.bounds)
      glass.style = .regular
      glass.wantsLayer = true
      glass.setAccessibilityElement(false)
      viewport.addSubview(glass, positioned: .above, relativeTo: surface)
      splitRevealGlass = glass
    }
    // Keep the effect tree at its render size for the entire flight. The shared
    // viewport transform and mask supply the moving outline; resizing native
    // glass and compensating its radius on every refresh produces warped rims.
    glass.frame = viewport.bounds
    glass.cornerRadius = BrowserLayout.contentCornerRadius
    glass.isHidden = false
    guard let layer = glass.layer else { return }
    if direction == .enter, let session = surface.delegate as? BrowserSession,
       !session.hasFinishedFirstLoad {
      // A pinned drop can create a new Chromium runtime. Keep the material
      // until that runtime completes its initial load instead of revealing an
      // empty native surface halfway through the card expansion.
      layer.opacity = fromOpacity
      surface.layer?.opacity = 0
      splitRevealLoadObservation = session.$hasFinishedFirstLoad
        .combineLatest(session.$rendererCrashed)
        .map { finished, crashed in finished || crashed }
        .filter { $0 }
        // Slow or crashed pages must still expose their normal loading/error
        // surface. The transition never holds interactive content indefinitely.
        .merge(with: Just(true).delay(
          for: .seconds(BrowserSplitRevealTransition.contentWaitDuration), scheduler: RunLoop.main))
        .prefix(1)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.revealLoadedSplitContent() }
      return
    }
    layer.opacity = toOpacity
    let fade = BrowserSplitRevealTransition.glassOpacityAnimation(direction, from: fromOpacity, to: toOpacity)
    fade.beginTime = 0
    layer.add(fade, forKey: "split-reveal-glass-fade")
  }

  private func revealLoadedSplitContent() {
    guard splitRevealLoadObservation != nil, let glassLayer = splitRevealGlass?.layer else { return }
    splitRevealLoadObservation = nil
    let token = UUID()
    splitRevealContentFadeToken = token
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.splitRevealContentFadeToken == token else { return }
        self.endSplitRevealGlass()
      }
    }
    for (layer, opacity) in [(glassLayer, Float(0)), (surface.layer, Float(1))] {
      guard let layer else { continue }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = (layer.presentation() ?? layer).opacity
      fade.toValue = opacity
      fade.duration = BrowserSplitRevealTransition.contentFadeDuration
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.opacity = opacity
      layer.add(fade, forKey: "split-reveal-content-fade")
    }
    CATransaction.commit()
  }

  func endSplitRevealGlass(preservingPendingContent: Bool = false) {
    if preservingPendingContent,
       splitRevealLoadObservation != nil || splitRevealContentFadeToken != nil { return }
    splitRevealLoadObservation = nil
    splitRevealContentFadeToken = nil
    surface.layer?.removeAnimation(forKey: "split-reveal-content-fade")
    surface.layer?.opacity = 1
    splitRevealGlass?.layer?.removeAnimation(forKey: "split-reveal-glass-fade")
    splitRevealGlass?.layer?.removeAnimation(forKey: "split-reveal-content-fade")
    splitRevealGlass?.isHidden = true
  }

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
