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
  private weak var installedWindow: NSWindow?

  init(tabID: UUID, surface: ChromiumContainerView, viewport: NSView) {
    self.tabID = tabID
    self.surface = surface
    self.viewport = viewport
    surface.autoresizingMask = []
    surface.setFrameOrigin(.zero)
    viewport.addSubview(surface)
  }

  /// Bare runtime hosts can mount Chromium without UI dependencies. Production
  /// configures the toolbar once, retaining it for the lifetime of this page.
  func configureToolbar(workspace: BrowserWorkspaceStore, history: HistoryService) {
    guard toolbar == nil else { return }
    toolbar = BrowserToolbarController(workspace: workspace, history: history,
      browserView: viewport, tabID: tabID, initiallyVisible: false)
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
    toolbar?.setPageControlsVisible(false, animated: animated)
  }

  func dispose() {
    toolbar?.dispose()
    viewport.removeFromSuperview()
  }
}
