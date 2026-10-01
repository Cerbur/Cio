//
//  BrowserMainViewController.swift
//  NativeBrowser
//
//  The shared, clipped content region for Space, History, and Downloads.
//  The Space sidebar and browser are rectangular; this view owns their edge.
//

import AppKit
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
  private var splitDropSide: BrowserSplitLayout.Side?
  let sidebarItem: NSSplitViewItem
  let browserItem: NSSplitViewItem
  let spaceSplitController: NSSplitViewController

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
    drag.externalBounds = { [weak self] in
      guard let self else { return .zero }
      return self.sidebarItem.viewController.view.convert(self.view.bounds, from: self.view)
    }
    drag.onPointerMove = { [weak self] id, point in
      guard let self else { return }
      let browser = self.browserItem.viewController.view
      let local = browser.convert(point, from: self.sidebarItem.viewController.view)
      let canSplit = self.runtime.presentedInternalPanel == nil
        && self.runtime.workspaceStore.canSplit(with: id) && browser.bounds.contains(local)
      self.splitDropSide = canSplit ? (local.x < browser.bounds.midX ? .left : .right) : nil
      self.runtime.workspaceStore.sessionManager.previewSplit(on: self.splitDropSide)
    }
    drag.onSplitDrop = { [weak self] id in
      guard let self, let side = self.splitDropSide else { return false }
      self.splitDropSide = nil
      return self.runtime.workspaceStore.sessionManager.commitSplitPreview {
        self.runtime.workspaceStore.splitTab(id, on: side)
      }
    }
    drag.onPreviewEnd = { [weak self] in
      self?.splitDropSide = nil
      self?.runtime.workspaceStore.sessionManager.previewSplit(on: nil)
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
      if let group = workspace.splitGroup(containing: id) {
        HStack(spacing: 2) {
          dragLabel(group.leftTabID, style: style)
          dragLabel(group.rightTabID, style: style)
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
