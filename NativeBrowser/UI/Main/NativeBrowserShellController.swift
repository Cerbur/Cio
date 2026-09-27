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
final class NativeBrowserShellController: NSSplitViewController {
  private let runtime: ApplicationRuntime
  private let sidebarChromeLayout = SidebarChromeLayout()
  private let mainViewController: BrowserMainViewController
  private lazy var browserToolbar = BrowserToolbarController(
    workspace: runtime.workspaceStore,
    browserView: browserItem.viewController.view,
    isSidebarCollapsed: { [weak self] in self?.sidebarItem.isCollapsed ?? true },
    onSidebarToggle: { [weak self] in self?.handleSidebarToggle() })
  private var sidebarItem: NSSplitViewItem { mainViewController.sidebarItem }
  private var browserItem: NSSplitViewItem { mainViewController.browserItem }
  private var spaceSplitView: NSSplitView { mainViewController.spaceSplitView }

  private var panelObservation: AnyCancellable?
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

    super.init(nibName: nil, bundle: nil)

    splitView = SeamlessSplitView()
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    addSplitViewItem(railItem)
    addSplitViewItem(mainItem)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeSidebarCollapse()
    observePanelSelection()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    // Configure full-size content before NSSplitViewController lays out its
    // full-height sidebar beneath the toolbar.
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
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateSidebarChromeLayout()
    browserToolbar.updateSidebarButtonPosition()
  }

  override func splitView(
    _ splitView: NSSplitView,
    shouldHideDividerAt dividerIndex: Int
  ) -> Bool {
    dividerIndex == 0 || super.splitView(splitView, shouldHideDividerAt: dividerIndex)
  }

  private func updateSidebarChromeLayout() {
    sidebarChromeLayout.update(topInset: 0)
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
    browserToolbar.setVisible(panel == nil)
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
        browserToolbar.insertLeadingSpacer()
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
      } completionHandler: { [weak self] in
        guard let self, self.sidebarItem.isCollapsed else { return }
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.16
          self.browserToolbar.removeLeadingSpacer()
        }
      }
    }
  }
}
