import CioEngine
import AppKit

/// A stable page UI module: one tab-bound toolbar and one Chromium surface.
/// Single-page, split and preview layouts all refer to the same instance. The
/// splitter host supplies and clips the viewport; the toolbar/editor mount in
/// the shell overlay so expanded address panels remain outside content clipping.
@MainActor
final class BrowserPagePresentation {
  private(set) var tabID: UUID
  let surface: any BrowserNativeSurface
  let viewport: NSView
  private(set) var toolbar: BrowserToolbarController?
  let splitControl = BrowserSplitPaneControl(frame: .zero)
  var onMinimizeToSidebar: (() -> Void)?
  lazy var splitTransition = BrowserSplitPageTransition(page: self)
  private weak var installedWindow: NSWindow?

  init(tabID: UUID, surface: any BrowserNativeSurface, viewport: NSView) {
    self.tabID = tabID
    self.surface = surface
    self.viewport = viewport
    surface.nativeView.autoresizingMask = []
    splitControl.dragSource = { [weak viewport] in
      guard let viewport else { return .zero }
      return viewport.convert(viewport.bounds, to: nil)
    }
    surface.nativeView.setFrameOrigin(.zero)
    viewport.addSubview(surface.nativeView)
  }

  /// Bare runtime hosts can mount Chromium without UI dependencies. Production
  /// configures the toolbar once, retaining it for the lifetime of this page.
  func configureToolbar(workspace: any BrowserWorkspaceProtocol, history: HistoryService) {
    guard toolbar == nil else { return }
    splitControl.onActivate = { [weak self, weak workspace] in
      guard let self else { return }
      workspace?.selectTab(id: self.tabID, focusingPage: true)
    }
    splitControl.onClose = { [weak self, weak workspace] in
      guard let self else { return }
      workspace?.closeTab(id: self.tabID)
    }
    splitControl.onMinimize = { [weak self, weak workspace] in
      if let action = self?.onMinimizeToSidebar { action() }
      else if let self { workspace?.detachSplitPane(self.tabID) }
    }
    splitControl.onExpand = { [weak self, weak workspace] in
      guard let self else { return }
      workspace?.detachSplitPane(self.tabID, selectDetached: true)
    }
    let toolbar = BrowserToolbarController(workspace: workspace, history: history,
      browserView: viewport, tabID: tabID, initiallyVisible: false)
    self.toolbar = toolbar
    splitControl.addressFrameProvider = { [weak toolbar] in toolbar?.addressCapsuleFrame(in: nil) }
    toolbar.onAddressCapsuleLayout = { [weak control = splitControl] in control?.addressLayoutDidChange() }
  }

  func transferOwnership(to tabID: UUID) {
    self.tabID = tabID
    toolbar?.transferOwnership(to: tabID)
  }

  func layout(in contentHost: NSView, chromeHost: NSView?, frame: CGRect,
              toolbarVisible: Bool, toolbarLayoutFrame: CGRect, animatedVisibility: Bool, animatedLayout: Bool) {
    let toolbarSource = toolbar?.captureLayout()
    viewport.isHidden = false
    if viewport.frame != frame { viewport.frame = frame }
    // Assign the final render size once. Split motion happens on the shared
    // viewport layer, never by repeatedly resizing Chromium during a flight.
    if surface.nativeView.frame != viewport.bounds { surface.nativeView.frame = viewport.bounds }
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
    // Install before resolving native host geometry; capture happened before
    // changing either the page frame or the chrome's coordinate system.
    if toolbar.view.frame != toolbarFrame { toolbar.view.frame = toolbarFrame }
    if installedWindow !== window {
      installedWindow = window
      toolbar.install(in: window)
    }
    if let toolbarSource {
      toolbar.layoutChrome(frame: toolbarFrame, from: toolbarSource, animated: animatedLayout)
    }
    toolbar.setPageControlsVisible(toolbarVisible, animated: animatedVisibility,
                                  animation: splitTransition.chromeRevealAnimation)
    toolbar.browserGeometryDidChange()
  }

  func hide(animated: Bool) {
    splitTransition.hideGlass()
    viewport.isHidden = true
    splitControl.setPresented(false)
    splitControl.collapse()
    toolbar?.setPageControlsVisible(false, animated: animated)
  }

  func dispose() {
    splitTransition.cancel()
    toolbar?.dispose()
    splitControl.removeFromSuperview()
    viewport.removeFromSuperview()
  }
}
