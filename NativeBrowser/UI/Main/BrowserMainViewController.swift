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
  let sidebarItem: NSSplitViewItem
  let browserItem: NSSplitViewItem
  let spaceSplitController: NSSplitViewController

  var spaceSplitView: NSSplitView { spaceSplitController.splitView }

  init(runtime: ApplicationRuntime, sidebarChromeLayout: SidebarChromeLayout) {
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
    NSLayoutConstraint.activate([
      spaceSplitController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      spaceSplitController.view.topAnchor.constraint(equalTo: container.topAnchor),
      spaceSplitController.view.trailingAnchor.constraint(
        equalTo: container.trailingAnchor),
      spaceSplitController.view.bottomAnchor.constraint(
        equalTo: container.bottomAnchor),
    ])
  }
}

/// Keeps the Chromium surface mounted across library section changes.
private struct BrowserShellContentView: View {
  @ObservedObject var runtime: ApplicationRuntime
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    ZStack {
      BrowserSurfaceView(manager: workspace.sessionManager)
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
    .background(Color(nsColor: .underPageBackgroundColor))
  }
}
