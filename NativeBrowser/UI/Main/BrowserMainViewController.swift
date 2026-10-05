//
//  BrowserMainViewController.swift
//  NativeBrowser
//
//  The shared, clipped content region for Space, History, and Downloads.
//  The Space sidebar and browser are rectangular; this view owns their edge.
//

import AppKit
import Combine
import SwiftUI

final class SeamlessSplitView: NSSplitView {
  override func drawDivider(in rect: NSRect) {}
}

@MainActor
final class BrowserMainViewController: NSViewController {
  private let runtime: ApplicationRuntime
  private let sidebarChromeLayout: SidebarChromeLayout
  private var dragOverlay: NSView?
  private weak var overlayDrag: SidebarTabDrag?
  private var splitDropTarget: BrowserSplitLayout.DropTarget?
  private var paneDropIndex: Int?
  let sidebarItem: NSSplitViewItem
  let browserItem: NSSplitViewItem
  let spaceSplitController: NSSplitViewController

  /// Section-owned control displayed in the shell overlay, outside content clips.
  private(set) lazy var spaceToolbar = SpaceToolbarController(onToggle: { [weak self] in
    self?.toggleSpaceSidebar()
  })
  var onToolbarLayoutChange: (() -> Void)?
  private var panelObservation: AnyCancellable?
  private var sidebarCommandObservation: AnyCancellable?
  private var sidebarCollapseObservation: NSKeyValueObservation?
  private var sidebarWasCollapsedBeforeLibrary = false
  private var wasShowingLibrary = false
  private var didRestoreSidebarWidth = false
  private var expandedSidebarWidth = BrowserLayout.sidebarDefaultWidth

  var spaceSplitView: NSSplitView { spaceSplitController.splitView }

  init(runtime: ApplicationRuntime, sidebarChromeLayout: SidebarChromeLayout) {
    self.runtime = runtime
    self.sidebarChromeLayout = sidebarChromeLayout
    let sidebarRootView = AnyView(
      TabSidebarView(workspace: runtime.workspaceStore)
        .environmentObject(sidebarChromeLayout)
        .frame(maxHeight: .infinity))
    let sidebarController = NSHostingController(rootView: sidebarRootView)
    let browserController = NSHostingController(
      rootView: BrowserShellContentView(runtime: runtime, workspace: runtime.workspaceStore))

    let sidebarItem = NSSplitViewItem(viewController: sidebarController)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.minimumThickness = BrowserLayout.sidebarMinimumWidth
    sidebarItem.maximumThickness = BrowserLayout.sidebarMaximumWidth
    sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    self.sidebarItem = sidebarItem

    let browserItem = NSSplitViewItem(viewController: browserController)
    self.browserItem = browserItem

    let splitController = NSSplitViewController()
    splitController.splitView = SeamlessSplitView()
    splitController.splitView.isVertical = true
    splitController.splitView.dividerStyle = .thin
    splitController.addSplitViewItem(sidebarItem)
    splitController.addSplitViewItem(browserItem)
    spaceSplitController = splitController
    sidebarChromeLayout.splitView = splitController.splitView

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.cornerRadius = BrowserLayout.contentCornerRadius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    view = container
    addChild(spaceSplitController)
    container.addSubview(spaceSplitController.view)
    spaceSplitController.view.translatesAutoresizingMaskIntoConstraints = false
    sidebarChromeLayout.onTabDragAvailable = { [weak self] drag in self?.installDragOverlay(drag) }
    NSLayoutConstraint.activate([
      spaceSplitController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      spaceSplitController.view.topAnchor.constraint(equalTo: container.topAnchor),
      spaceSplitController.view.trailingAnchor.constraint(
        equalTo: container.trailingAnchor),
      spaceSplitController.view.bottomAnchor.constraint(
        equalTo: container.bottomAnchor),
    ])
  }
  override func viewDidLoad() {
    super.viewDidLoad()
    spaceToolbar.setVisible(runtime.presentedInternalPanel == nil, animated: false)
    sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.spaceToolbar.setCollapsed(self.sidebarItem.isCollapsed)
        self.onToolbarLayoutChange?()
      }
    }
    panelObservation = runtime.$presentedInternalPanel.receive(on: RunLoop.main).sink { [weak self] panel in
      MainActor.assumeIsolated { self?.showSection(panel) }
    }
    sidebarCommandObservation = NotificationCenter.default.publisher(
      for: .browserToggleSidebar, object: runtime.workspaceStore).sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.runtime.presentedInternalPanel == nil else { return }
          self.toggleSpaceSidebar()
        }
      }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    if !didRestoreSidebarWidth {
      didRestoreSidebarWidth = true
      let defaults = UserDefaults.standard
      var saved = defaults.double(forKey: BrowserLayout.sidebarWidthPreferenceKey)
      if !defaults.bool(forKey: BrowserLayout.sidebarWidthMigrationKey) {
        if saved == 210 { saved = Double(BrowserLayout.sidebarMinimumWidth) }
        defaults.set(true, forKey: BrowserLayout.sidebarWidthMigrationKey)
      }
      let desired = saved > 0 ? CGFloat(saved) : BrowserLayout.sidebarDefaultWidth
      expandedSidebarWidth = min(max(desired, BrowserLayout.sidebarMinimumWidth), BrowserLayout.sidebarMaximumWidth)
      spaceSplitView.setPosition(expandedSidebarWidth, ofDividerAt: 0)
    }
    onToolbarLayoutChange?()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    onToolbarLayoutChange?()
  }

  func layoutSpaceToolbar(in host: NSView, windowControlsTrailingEdge: CGFloat) {
    let anchor = browserItem.viewController.view.convert(browserItem.viewController.view.bounds, to: host)
    spaceToolbar.layout(in: host, sidebarAnchor: anchor, windowControlsTrailingEdge: windowControlsTrailingEdge)
  }

  private func showSection(_ panel: ApplicationRuntime.InternalBrowserPanel?) {
    // Space owns both sidebar state and the lifetime/visibility of its control.
    if panel != nil {
      if !wasShowingLibrary {
        sidebarWasCollapsedBeforeLibrary = sidebarItem.isCollapsed
        if !sidebarItem.isCollapsed { toggleSpaceSidebar() }
      }
      wasShowingLibrary = true
    } else if wasShowingLibrary {
      wasShowingLibrary = false
      if !sidebarWasCollapsedBeforeLibrary && sidebarItem.isCollapsed { toggleSpaceSidebar() }
    }
    spaceToolbar.setVisible(panel == nil, animated: true)
  }

  private func toggleSpaceSidebar() {
    if sidebarItem.isCollapsed {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.28
        sidebarItem.animator().isCollapsed = false
      }
      let width = expandedSidebarWidth
      DispatchQueue.main.async { [weak self] in self?.spaceSplitView.setPosition(width, ofDividerAt: 0) }
    } else {
      expandedSidebarWidth = sidebarItem.viewController.view.frame.width
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.28
        sidebarItem.animator().isCollapsed = true
      }
    }
  }

  private func installDragOverlay(_ drag: SidebarTabDrag) {
    // Sidebar reattachment during tier changes must preserve the glass namespace.
    if overlayDrag === drag, dragOverlay != nil { return }
    dragOverlay?.removeFromSuperview()
    let overlay = BrowserTabDragHostingView(rootView: BrowserTabDragPresentation(
      drag: drag, workspace: runtime.workspaceStore))
    overlay.safeAreaRegions = []
    overlay.frame = view.bounds
    overlay.autoresizingMask = [.width, .height]
    view.addSubview(overlay, positioned: .above, relativeTo: nil)
    dragOverlay = overlay
    overlayDrag = drag
    var splitLandingTabIDs: [UUID] = []
    runtime.workspaceStore.sessionManager.onSplitPaneDrag = { [weak self, weak drag] id, event in
      guard let self, let drag else { return false }
      let sidebar = self.sidebarItem.viewController.view
      switch event {
      case .begin(let point, let frame, let snapshot):
        guard self.runtime.presentedInternalPanel == nil,
              let group = self.runtime.workspaceStore.activeSplit, group.contains(id) else { return false }
        let workspace = self.runtime.workspaceStore
        let tier: WorkspaceCollection.TabTier = workspace.globalPinnedTabs.contains(where: { $0.id == id }) ? .global
          : (workspace.selectedSpace?.pinnedTabIDs.contains(id) == true ? .space(workspace.selectedSpaceID) : .temporary(workspace.selectedSpaceID))
        guard drag.beginPane(id, tier: tier, at: sidebar.convert(point, from: nil),
                             frame: sidebar.convert(frame, from: nil), snapshot: snapshot,
                             groupTabIDs: group.tabIDs) else { return false }
        splitLandingTabIDs = [id]
        self.paneDropIndex = nil
        workspace.sessionManager.previewPaneDrag(id)
        return true
      case .move(let point):
        drag.movePane(to: sidebar.convert(point, from: nil))
      case .end:
        drag.drop { [weak self] id, target in self?.runtime.workspaceStore.moveSplitPane(id, to: target) ?? false }
      case .cancel:
        drag.gestureDidEnd()
      }
      return true
    }
    drag.isStableTab = { [weak workspace = runtime.workspaceStore] id in
      guard let workspace, !workspace.isSpotlightPresented, let selectedID = workspace.selectedTabID else { return false }
      return workspace.splitGroup(containing: id)?.contains(selectedID) ?? (id == selectedID)
    }
    drag.externalBounds = { [weak self] in
      guard let self else { return .zero }
      return self.sidebarItem.viewController.view.convert(self.view.bounds, from: self.view)
    }
    drag.onPointerMove = { [weak self, weak drag] id, point in
      guard let self, let drag else { return }
      let browser = self.browserItem.viewController.view
      let local = browser.convert(point, from: self.sidebarItem.viewController.view)
      if drag.isPaneDrag, let group = self.runtime.workspaceStore.activeSplit {
        let canDrop = browser.bounds.contains(local)
        self.paneDropIndex = canDrop ? group.dropPaneIndex(at: local.x, in: browser.bounds) : nil
        self.runtime.workspaceStore.sessionManager.previewPaneDrag(id, index: self.paneDropIndex)
        return
      }
      let canSplit = self.runtime.presentedInternalPanel == nil
        && self.runtime.workspaceStore.canSplit(with: id) && browser.bounds.contains(local)
      self.splitDropTarget = canSplit ? (self.runtime.workspaceStore.activeSplit?.dropTarget(at: local.x, in: browser.bounds)
        ?? BrowserSplitLayout.DropTarget(side: BrowserSplitLayout.dropSide(at: local.x, in: browser.bounds))) : nil
      let count = self.runtime.workspaceStore.splitGroup(containing: id)?.tabIDs.count ?? 1
      self.runtime.workspaceStore.sessionManager.previewSplit(at: self.splitDropTarget, incomingPaneCount: count)
    }
    drag.onSplitRevealFrame = { [weak self] frame in
      guard let self else { return }
      let windowFrame = frame.flatMap { frame in
        self.dragOverlay?.convert(frame, to: nil)
      }
      self.runtime.workspaceStore.sessionManager.setSplitReveal(
        for: splitLandingTabIDs, frame: windowFrame)
    }
    drag.onSplitLandingFrame = { [weak self] in
      guard let self, let frame = self.runtime.workspaceStore.sessionManager
        .splitLandingFrame(for: splitLandingTabIDs) else { return nil }
      return self.sidebarItem.viewController.view.convert(frame, from: nil)
    }
    drag.onSplitDrop = { [weak self, weak drag] id in
      guard let self else { return false }
      if drag?.isPaneDrag == true {
        guard let index = self.paneDropIndex else { return false }
        splitLandingTabIDs = [id]
        drag?.prepareSplitLanding(tabIDs: splitLandingTabIDs)
        return self.runtime.workspaceStore.sessionManager.commitSplitPreview {
          self.runtime.workspaceStore.reorderSplitPane(id, to: index)
        }
      }
      guard let target = self.splitDropTarget else { return false }
      let incomingIDs = self.runtime.workspaceStore.splitGroup(containing: id)?.tabIDs ?? [id]
      drag?.prepareSplitLanding(tabIDs: incomingIDs)
      self.splitDropTarget = nil
      let committed = self.runtime.workspaceStore.sessionManager.commitSplitPreview {
        self.runtime.workspaceStore.splitTab(id, at: target)
      }
      splitLandingTabIDs = []
      if committed, let group = self.runtime.workspaceStore.activeSplit,
         let focusedID = group.focusedTabID,
         let focusedIndex = group.tabIDs.firstIndex(of: focusedID),
         let sourceIndex = incomingIDs.firstIndex(of: id) {
        // Pinned sources create temporary copies for a split. Reveal the new
        // committed identities while the floating card keeps its source label.
        let first = focusedIndex - sourceIndex
        let end = first + incomingIDs.count
        if first >= 0, end <= group.tabIDs.count {
          splitLandingTabIDs = Array(group.tabIDs[first..<end])
        }
      }
      return committed
    }
    drag.onPreviewEnd = { [weak self] in
      self?.splitDropTarget = nil
      self?.paneDropIndex = nil
      self?.runtime.workspaceStore.sessionManager.previewPaneDrag(nil)
      self?.runtime.workspaceStore.sessionManager.previewSplit(at: nil)
    }
  }

}

/// Keeps the Chromium surface mounted across library section changes.
private struct BrowserShellContentView: View {
  @ObservedObject var runtime: ApplicationRuntime
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    ZStack {
      BrowserSurfaceView(manager: workspace.sessionManager, workspace: workspace, history: runtime.historyService, isCovered: runtime.presentedInternalPanel != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let panel = runtime.presentedInternalPanel {
        BrowserLibraryView(
          panel: panel,
          history: runtime.historyService,
          downloads: runtime.downloadManager,
          workspace: workspace,
          onClose: { runtime.presentedInternalPanel = nil })
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if runtime.presentedInternalPanel == nil,
         let session = workspace.selectedSession, session.rendererCrashed {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 28))
            .accessibilityHidden(true)
          Text("This page stopped responding")
            .font(.headline)
          Text("The page process ended unexpectedly. Reload to start it again.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
          Button("Reload") {
            session.reload()
          }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("renderer-crash-reload")
        }
        .padding(28)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page stopped responding")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Chromium containers paint their own page background. Keep the surface
    // between panes transparent so it exposes the same backdrop as the toolbar.
  }
}

/// Draw the block over the full Main View so leaving the sidebar never clips it.
private final class BrowserTabDragHostingView: NSHostingView<BrowserTabDragPresentation> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BrowserTabDragPresentation: View {
  let drag: SidebarTabDrag
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    SidebarTabDragOverlay(drag: drag) { id, style in
      if !drag.isPaneDrag, let members = drag.splitLandingTabIDs ?? workspace.splitGroup(containing: id)?.tabIDs {
        HStack(spacing: 2) {
          ForEach(members, id: \.self) { memberID in
            dragLabel(memberID, style: style)
          }
        }
      } else {
        dragLabel(id, style: style)
      }
    }
  }

  @ViewBuilder
  private func dragLabel(_ id: UUID, style: SidebarTabDrag.Style) -> some View {
    if let tab = workspace.tab(withID: id) {
      DragContent(
        pageURL: tab.url, session: workspace.session(for: id),
        title: tab.displayTitle, fallbackLetter: tab.pinFallbackLetter,
        rowAmount: style == .row ? 1 : 0, cardAmount: style == .card ? 1 : 0)
        .opacity(1 - drag.paneSnapshotOpacity)
        .overlay {
          if let snapshot = drag.paneSnapshot {
            // A fading page snapshot must never impose its aspect ratio on
            // the row/tile underneath it as the drag enters the sidebar.
            GeometryReader { geometry in
              Image(nsImage: snapshot).resizable().scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped().opacity(drag.paneSnapshotOpacity)
            }
          }
        }
    }
  }

  /// All styles share one favicon and two permanently mounted title layouts.
  /// Interpolating layout values keeps the icon's size and position continuous;
  /// title opacity can change without replacing either text view.
  private struct DragContent: View, Animatable {
    let pageURL: URL?
    let session: BrowserSession?
    let title: String
    let fallbackLetter: String?
    nonisolated var rowAmount: CGFloat
    nonisolated var cardAmount: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
      get { AnimatablePair(rowAmount, cardAmount) }
      set {
        rowAmount = newValue.first
        cardAmount = newValue.second
      }
    }

    var body: some View {
      GeometryReader { geometry in
        let width = geometry.size.width
        let height = geometry.size.height
        let iconSize = SidebarTabAppearance.faviconSize + 22 * cardAmount
        let rowTitleWidth = max(width - 51, 1)
        ZStack(alignment: .topLeading) {
          TabFaviconView(
            pageURL: pageURL, session: session, size: iconSize,
            fallbackLetter: fallbackLetter)
            .position(
              x: width / 2 + (21 - width / 2) * rowAmount,
              y: height / 2)

          Text(title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .frame(width: rowTitleWidth, alignment: .leading)
            .position(x: 40 + rowTitleWidth / 2, y: height / 2)
            .opacity(Double(min(max(rowAmount, 0), 1)))

          Text(title)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(width: max(width - 24, 1), height: max(height * 0.3, 1))
            .position(x: width / 2, y: height * 0.79)
            .opacity(Double(min(max(cardAmount, 0), 1)))
        }
      }
    }
  }
}
