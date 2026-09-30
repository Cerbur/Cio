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

@MainActor
private final class ShellSplitController: NSSplitViewController {
  override func splitView(
    _ splitView: NSSplitView,
    shouldHideDividerAt dividerIndex: Int
  ) -> Bool {
    dividerIndex == 0 || super.splitView(splitView, shouldHideDividerAt: dividerIndex)
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
  private let shellSplitController: ShellSplitController
  private lazy var browserToolbar = BrowserToolbarController(
    workspace: runtime.workspaceStore,
    history: runtime.historyService,
    browserView: browserItem.viewController.view,
    isSidebarCollapsed: { [weak self] in self?.sidebarItem.isCollapsed ?? true },
    onSidebarToggle: { [weak self] in self?.handleSidebarToggle() })
  private var sidebarItem: NSSplitViewItem { mainViewController.sidebarItem }
  private var browserItem: NSSplitViewItem { mainViewController.browserItem }
  private var spaceSplitView: NSSplitView { mainViewController.spaceSplitView }

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
    let railHostingController = NSHostingController(rootView: NavigationRail(runtime: runtime))
    let railItem = NSSplitViewItem(viewController: railHostingController)
    railItem.minimumThickness = BrowserLayout.railWidth
    railItem.maximumThickness = BrowserLayout.railWidth
    railItem.canCollapse = false
    let mainItem = NSSplitViewItem(viewController: mainViewController)
    mainItem.canCollapse = false

    let splitController = ShellSplitController()
    splitController.splitView = SeamlessSplitView()
    splitController.splitView.isVertical = true
    splitController.splitView.dividerStyle = .thin
    splitController.addSplitViewItem(railItem)
    splitController.addSplitViewItem(mainItem)
    shellSplitController = splitController

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let shellView = NSView()
    view = shellView
    addChild(shellSplitController)
    shellView.addSubview(shellSplitController.view)
    shellSplitController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      shellSplitController.view.leadingAnchor.constraint(equalTo: shellView.leadingAnchor),
      shellSplitController.view.trailingAnchor.constraint(equalTo: shellView.trailingAnchor),
      shellSplitController.view.topAnchor.constraint(equalTo: shellView.topAnchor),
      shellSplitController.view.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeSidebarCollapse()
    observePanelSelection()
    observeSpotlight()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    // Configure full-size content before the nested split controller lays out
    // its full-height sidebar beneath the toolbar.
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
    updateSpotlightPresentation(runtime.workspaceStore.isSpotlightPresented)
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

  /// The overlay is a sibling of the entire rail/sidebar/browser split, so it
  /// uses the shell's full bounds and stays above every content section.
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
    view.addSubview(hostingView, positioned: .above, relativeTo: shellSplitController.view)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: view.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
