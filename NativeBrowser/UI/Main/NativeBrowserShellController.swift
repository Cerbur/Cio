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

/// Three siblings over the shell glass. Only Main View clips its children.
@MainActor
private final class BrowserShellView: NSView {
  let toolbarView: NSView
  let railView: NSView
  let mainView: NSView
  var onLayout: (() -> Void)?

  init(toolbarView: NSView, railView: NSView, mainView: NSView) {
    self.toolbarView = toolbarView
    self.railView = railView
    self.mainView = mainView
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("browser-shell-chrome-host")
    addSubview(mainView)
    addSubview(railView)
    addSubview(toolbarView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Resolve the entire toolbar background before overlapping pane and
    // SwiftUI hosts can claim it. Visible controls retain normal hit-testing;
    // all other toolbar points share the shell's drag and double-click handler.
    if !isHidden, bounds.contains(convert(point, from: superview)),
       let toolbar = toolbarView as? ToolbarChromeView,
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
  private lazy var browserToolbar = BrowserToolbarController(
    workspace: runtime.workspaceStore,
    history: runtime.historyService,
    browserView: browserItem.viewController.view,
    isSidebarCollapsed: { [weak self] in self?.sidebarItem.isCollapsed ?? true },
    onSidebarToggle: { [weak self] in self?.handleSidebarToggle() })
  private var sidebarItem: NSSplitViewItem { mainViewController.sidebarItem }
  private var browserItem: NSSplitViewItem { mainViewController.browserItem }
  private var spaceSplitView: NSSplitView { mainViewController.spaceSplitView }

  private var splitObservation: AnyCancellable?
  private var panelObservation: AnyCancellable?
  private var spotlightObservation: AnyCancellable?
  private var spotlightHostingView: SpotlightHostingView?
  private var spotlightPresentationState: SpotlightPresentationState?
  private var spotlightRemovalTask: Task<Void, Never>?
  private var sidebarWasCollapsedBeforeLibrary = false
  private var wasShowingLibrary = false
  private var sidebarCollapseObservation: NSKeyValueObservation?
  private var didRestoreSidebarWidth = false
  private var expandedSidebarWidth = BrowserLayout.sidebarDefaultWidth

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
      toolbarView: browserToolbar.view,
      railView: railController.view,
      mainView: mainViewController.view)
    shellView.onLayout = { [weak self] in self?.browserToolbar.browserGeometryDidChange() }
    runtime.workspaceStore.sessionManager.onSelectedSurfaceFrameChange = { [weak self] host, frame in
      guard let self else { return }
      // A split commit replaces the shell controls with pane controls before
      // resetting the hidden shell's geometry; do not flash them at full width.
      self.updateSplitToolbar()
      let local = frame.map { host.convert($0, to: self.browserItem.viewController.view) }
      self.browserToolbar.setBrowserViewportFrame(local)
    }
    view = shellView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeSidebarCollapse()
    observePanelSelection()
    observeSpotlight()
    splitObservation = runtime.workspaceStore.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { [weak self] in self?.updateSplitToolbar() }
    }
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    // The shell fills the native titlebar area and positions its own chrome.
    if let window = view.window {
      browserToolbar.install(in: window, showsSpaceToolbar: runtime.presentedInternalPanel == nil)
    }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    if !didRestoreSidebarWidth {
      didRestoreSidebarWidth = true
      let defaults = UserDefaults.standard
      var saved = defaults.double(forKey: BrowserLayout.sidebarWidthPreferenceKey)
      if !defaults.bool(forKey: BrowserLayout.sidebarWidthMigrationKey) {
        // A sidebar saved at the previous minimum should open at the new minimum.
        if saved == 210 {
          saved = Double(BrowserLayout.sidebarMinimumWidth)
          defaults.set(saved, forKey: BrowserLayout.sidebarWidthPreferenceKey)
        }
        defaults.set(true, forKey: BrowserLayout.sidebarWidthMigrationKey)
      }
      let desired = saved > 0 ? CGFloat(saved) : BrowserLayout.sidebarDefaultWidth
      expandedSidebarWidth = min(max(desired, BrowserLayout.sidebarMinimumWidth),
                                 BrowserLayout.sidebarMaximumWidth)
      spaceSplitView.setPosition(expandedSidebarWidth, ofDividerAt: 0)
    }
    if let window = view.window {
      browserToolbar.install(in: window, showsSpaceToolbar: runtime.presentedInternalPanel == nil)
    }
    updateSidebarChromeLayout()
    updateSplitToolbar()
    updateSpotlightPresentation(runtime.workspaceStore.isSpotlightPresented)
    if !runtime.workspaceStore.isSpotlightPresented {
      runtime.workspaceStore.selectedSession?.focusPage()
    }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateSidebarChromeLayout()
    browserToolbar.browserGeometryDidChange()
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

  private func observePanelSelection() {
    panelObservation = runtime.$presentedInternalPanel
      .receive(on: RunLoop.main)
      .sink { [weak self] panel in
        MainActor.assumeIsolated {
          self?.showSection(panel)
        }
      }
  }

  private func showSection(_ panel: ApplicationRuntime.InternalBrowserPanel?) {
    if panel != nil {
      if !wasShowingLibrary {
        sidebarWasCollapsedBeforeLibrary = sidebarItem.isCollapsed
        if !sidebarItem.isCollapsed { toggleSpaceSidebar() }
      }
      wasShowingLibrary = true
    } else if wasShowingLibrary {
      wasShowingLibrary = false
      if !sidebarWasCollapsedBeforeLibrary && sidebarItem.isCollapsed {
        toggleSpaceSidebar()
      }
    }
    browserToolbar.setSpaceControlsVisible(panel == nil)
    browserToolbar.updateSidebarState()
    updateSplitToolbar()
  }

  private func updateSplitToolbar() {
    browserToolbar.setPageControlsVisible(
      runtime.presentedInternalPanel == nil && runtime.workspaceStore.activeSplit == nil)
  }

  private func observeSidebarCollapse() {
    sidebarCollapseObservation = sidebarItem.observe(
      \.isCollapsed,
      options: [.initial, .new]
    ) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.browserToolbar.updateSidebarState()
      }
    }
  }

  private func handleSidebarToggle() {
    if runtime.presentedInternalPanel != nil {
      runtime.presentedInternalPanel = nil
      if sidebarWasCollapsedBeforeLibrary { toggleSpaceSidebar() }
      return
    }
    toggleSpaceSidebar()
  }

  func toggleSpaceSidebar() {
    if sidebarItem.isCollapsed {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.28
        sidebarItem.animator().isCollapsed = false
      }
      let width = expandedSidebarWidth
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.spaceSplitView.setPosition(width, ofDividerAt: 0)
      }
    } else {
      expandedSidebarWidth = sidebarItem.viewController.view.frame.width
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.28
        sidebarItem.animator().isCollapsed = true
      }
    }
  }
}
