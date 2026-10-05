//
//  NativeBrowserShellController.swift
//  NativeBrowser
//
//  AppKit presentation shell around the application's existing SwiftUI sidebar
//  and stable Chromium surface.
//

import AppKit
import Combine
import SwiftUI

struct NativeBrowserShellRepresentable: NSViewControllerRepresentable {
  let runtime: ApplicationRuntime

  func makeNSViewController(context: Context) -> NativeBrowserShellController {
    NativeBrowserShellController(runtime: runtime)
  }

  func updateNSViewController(
    _ controller: NativeBrowserShellController,
    context: Context
  ) {}
}

/// Empty overlay space passes through; mounted pane controls own their hits.
@MainActor
private final class SplitPaneOverlayHostView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    // SwiftUI address hosts are layer-backed. Composite pane actions as one
    // layer above them, rather than mixing their AppKit drawing underneath
    // the address host's separately composited text and glass layers.
    wantsLayer = true
    layer?.zPosition = 1
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// Shell sections share the glass, with pane actions in a dedicated top layer.
@MainActor
private final class BrowserShellView: NSView, BrowserToolbarLayoutHosting {
  let toolbarView: NSView
  let railView: NSView
  let mainView: NSView
  let splitPaneOverlayHost: NSView = SplitPaneOverlayHostView()
  var onLayout: (() -> Void)?
  var controlsLeadingEdge: (() -> CGFloat)?
  var pageControlsLeadingEdge: CGFloat { controlsLeadingEdge?() ?? 0 }

  init(toolbarView: NSView, railView: NSView, mainView: NSView) {
    self.toolbarView = toolbarView
    self.railView = railView
    self.mainView = mainView
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("browser-shell-chrome-host")
    addSubview(mainView)
    addSubview(railView)
    addSubview(toolbarView)
    addSubview(splitPaneOverlayHost)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isFlipped: Bool { true }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    // Address hosts may be mounted later or recreated. Their insertion must
    // never put them above the pane-action layer.
    if subview !== splitPaneOverlayHost, splitPaneOverlayHost.superview === self,
       subviews.last !== splitPaneOverlayHost {
      addSubview(splitPaneOverlayHost, positioned: .above, relativeTo: nil)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if let hit = splitPaneOverlayHost.hitTest(convert(point, from: superview)) {
      return hit
    }
    // Resolve the entire toolbar background before overlapping pane and
    // SwiftUI hosts can claim it. Visible controls retain normal hit-testing;
    // all other toolbar points share the shell's drag and double-click handler.
    if !isHidden, bounds.contains(convert(point, from: superview)),
       let toolbar = toolbarView as? BrowserWindowChromeView,
       toolbar.isWindowInteraction(at: superview?.convert(point, to: nil) ?? point) {
      return toolbar
    }
    return super.hitTest(point)
  }

  override func layout() {
    super.layout()
    let frames = BrowserShellFrames(bounds: bounds)
    toolbarView.frame = frames.toolbar
    railView.frame = frames.navigationRail
    mainView.frame = frames.mainView
    splitPaneOverlayHost.frame = bounds
    onLayout?()
  }
}

/// Spotlight keeps the sidebar covered except for visible tab selection buttons.
private final class SpotlightHostingView: NSHostingView<SpotlightView> {
  weak var sidebarView: NSView?
  var tabSelectionAtSidebarPoint: ((CGPoint) -> UUID?)?

  override func hitTest(_ point: NSPoint) -> NSView? {
    if let sidebarView, sidebarView.window === window {
      let sidebarPoint = sidebarView.convert(point, from: superview)
      if sidebarView.bounds.contains(sidebarPoint),
         tabSelectionAtSidebarPoint?(sidebarPoint) != nil {
        return nil
      }
    }
    return super.hitTest(point)
  }
}

@MainActor
final class NativeBrowserShellController: NSViewController {
  private let runtime: ApplicationRuntime
  private let sidebarChromeLayout = SidebarChromeLayout()
  private let mainViewController: BrowserMainViewController
  private let railController: NSHostingController<NavigationRail>
  private let windowChrome = BrowserWindowChromeView()
  private var sidebarItem: NSSplitViewItem { mainViewController.sidebarItem }

  private var spotlightObservation: AnyCancellable?
  private var spotlightHostingView: SpotlightHostingView?
  private var spotlightPresentationState: SpotlightPresentationState?
  private var spotlightRemovalTask: Task<Void, Never>?
  init(runtime: ApplicationRuntime) {
    self.runtime = runtime
    mainViewController = BrowserMainViewController(
      runtime: runtime, sidebarChromeLayout: sidebarChromeLayout)
    railController = NSHostingController(rootView: NavigationRail(runtime: runtime))
    railController.safeAreaRegions = []

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    addChild(mainViewController)
    addChild(railController)
    let shellView = BrowserShellView(
      toolbarView: windowChrome,
      railView: railController.view,
      mainView: mainViewController.view)
    shellView.controlsLeadingEdge = { [weak self, weak shellView] in
      guard let self, let shellView else { return 0 }
      return self.mainViewController.spaceToolbar.trailingEdge(in: shellView)
    }
    windowChrome.isControlAtWindowPoint = { [weak self, weak shellView] point in
      guard let self, let shellView else { return false }
      if self.mainViewController.spaceToolbar.containsControl(at: point) { return true }
      if shellView.splitPaneOverlayHost.subviews.compactMap({ $0 as? BrowserSplitPaneControl })
        .contains(where: { $0.containsControl(at: point) }) { return true }
      return shellView.subviews.compactMap { $0 as? ToolbarChromeView }
        .contains { $0.containsControl(at: point) }
    }
    let updateGeometry = { [weak self, weak shellView] in
      guard let self, let shellView else { return }
      let edge = shellView.convert(NSPoint(x: self.windowChrome.trafficLightsTrailingEdge, y: 0),
                                   from: self.windowChrome).x
      self.mainViewController.layoutSpaceToolbar(in: shellView, windowControlsTrailingEdge: edge)
      for case let pageChrome as ToolbarChromeView in shellView.subviews { pageChrome.refreshLayout() }
    }
    shellView.onLayout = updateGeometry
    mainViewController.onToolbarLayoutChange = updateGeometry
    view = shellView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeSpotlight()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    // The shell fills the native titlebar area and positions its own chrome.
    if let window = view.window {
      windowChrome.install(in: window)
    }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    if let window = view.window {
      windowChrome.install(in: window)
    }
    updateSidebarChromeLayout()
    updateSpotlightPresentation(runtime.workspaceStore.isSpotlightPresented)
    if !runtime.workspaceStore.isSpotlightPresented {
      runtime.workspaceStore.selectedSession?.focusPage()
    }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateSidebarChromeLayout()
    mainViewController.onToolbarLayoutChange?()
  }

  private func updateSidebarChromeLayout() {
    sidebarChromeLayout.update(topInset: 0)
  }

  private func observeSpotlight() {
    spotlightObservation = runtime.workspaceStore.$isSpotlightPresented
      .receive(on: RunLoop.main)
      .sink { [weak self] isPresented in
        MainActor.assumeIsolated {
          self?.updateSpotlightPresentation(isPresented)
        }
      }
  }

  /// Spotlight covers the content below the toolbar and beside the rail.
  private func updateSpotlightPresentation(_ isPresented: Bool) {
    spotlightRemovalTask?.cancel()
    if let hostingView = spotlightHostingView {
      spotlightPresentationState?.isPresented = isPresented
      if !isPresented {
        spotlightRemovalTask = Task { @MainActor [weak self, weak hostingView] in
          try? await Task.sleep(for: .milliseconds(170))
          guard !Task.isCancelled,
                let self, let hostingView,
                self.spotlightHostingView === hostingView else { return }
          hostingView.removeFromSuperview()
          self.spotlightHostingView = nil
          self.spotlightPresentationState = nil
        }
      }
      return
    }
    guard isPresented else { return }

    let presentation = SpotlightPresentationState()
    let hostingView = SpotlightHostingView(rootView: makeSpotlightView(presentation: presentation))
    hostingView.sidebarView = sidebarItem.viewController.view
    hostingView.tabSelectionAtSidebarPoint = { [weak self] point in
      guard let self else { return nil }
      return self.sidebarChromeLayout.tabDrag?.tabSelection(
        at: point, in: self.runtime.workspaceStore.selectedSpaceID)
    }
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hostingView, positioned: .above, relativeTo: mainViewController.view)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: mainViewController.view.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: mainViewController.view.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: mainViewController.view.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: mainViewController.view.bottomAnchor),
    ])
    spotlightHostingView = hostingView
    spotlightPresentationState = presentation
  }

  private func makeSpotlightView(presentation: SpotlightPresentationState) -> SpotlightView {
    let runtime = self.runtime
    return SpotlightView(
      presentation: presentation,
      autocomplete: SpotlightAutocompleteService(history: runtime.historyService),
      onSelect: { mode in runtime.performSpotlightAction(mode.action) },
      onDismiss: { runtime.dismissSpotlight() })
  }

}
