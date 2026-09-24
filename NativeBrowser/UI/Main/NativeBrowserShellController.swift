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
final class NativeBrowserShellController: NSSplitViewController, NSToolbarDelegate {
  private enum ToolbarID {
    static let newTab = NSToolbarItem.Identifier("cio.new-tab")
    static let toggleSidebar = NSToolbarItem.Identifier("cio.toggle-sidebar")
    static let back = NSToolbarItem.Identifier("cio.back")
    static let forward = NSToolbarItem.Identifier("cio.forward")
    static let reload = NSToolbarItem.Identifier("cio.reload")
    static let address = NSToolbarItem.Identifier("cio.address")
    static let trackingSeparator = NSToolbarItem.Identifier("cio.sidebar-tracking-separator")
  }

  private let runtime: ApplicationRuntime
  private let workspace: BrowserWorkspaceStore
  private let sidebarItem: NSSplitViewItem
  private let browserItem: NSSplitViewItem

  private var toolbar: NSToolbar?
  private var newTabToolbarItem: NSToolbarItem?
  private var sidebarToolbarItem: NSToolbarItem?
  private var backToolbarItem: NSToolbarItem?
  private var forwardToolbarItem: NSToolbarItem?
  private var reloadToolbarItem: NSToolbarItem?
  private var workspaceObservation: AnyCancellable?
  private var selectedSessionObservation: AnyCancellable?
  private weak var observedSession: BrowserSession?
  private var sidebarCollapseObservation: NSKeyValueObservation?

  init(runtime: ApplicationRuntime) {
    self.runtime = runtime
    workspace = runtime.workspaceStore

    let sidebarHostingController = NSHostingController(
      rootView: TabSidebarView(workspace: runtime.workspaceStore)
        .environmentObject(runtime)
        .frame(maxHeight: .infinity))
    let browserHostingController = NSHostingController(
      rootView: BrowserShellContentView(workspace: runtime.workspaceStore))

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.minimumThickness = BrowserLayout.sidebarWidth
    sidebarItem.maximumThickness = BrowserLayout.sidebarWidth
    sidebarItem.allowsFullHeightLayout = true
    sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    self.sidebarItem = sidebarItem

    let browserItem = NSSplitViewItem(viewController: browserHostingController)
    self.browserItem = browserItem

    super.init(nibName: nil, bundle: nil)

    splitView.isVertical = true
    splitView.dividerStyle = .thin
    addSplitViewItem(sidebarItem)
    addSplitViewItem(browserItem)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeSidebarCollapse()
    observeWorkspace()
    refreshSelectedSessionObservation()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    installToolbarIfNeeded()
  }

  private func installToolbarIfNeeded() {
    guard let window = view.window else { return }

    if toolbar == nil {
      let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cio.native-browser-toolbar"))
      toolbar.delegate = self
      toolbar.displayMode = .iconOnly
      toolbar.allowsUserCustomization = false
      self.toolbar = toolbar
    }

    if !window.styleMask.contains(.fullSizeContentView) {
      window.styleMask.insert(.fullSizeContentView)
    }
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    if window.toolbar !== toolbar {
      window.toolbar = toolbar
    }
    refreshToolbarState()
  }

  private func observeSidebarCollapse() {
    sidebarCollapseObservation = sidebarItem.observe(
      \.isCollapsed,
      options: [.initial, .new]
    ) { [weak self] _, _ in
      MainActor.assumeIsolated {
        self?.updateToolbarSectionVisibility()
      }
    }
  }

  private func observeWorkspace() {
    workspaceObservation = workspace.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refreshSelectedSessionObservation()
        }
      }
  }

  private func refreshSelectedSessionObservation() {
    let selectedSession = workspace.selectedSession
    guard observedSession !== selectedSession else {
      refreshToolbarState()
      return
    }

    observedSession = selectedSession
    selectedSessionObservation = selectedSession?.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refreshToolbarState()
        }
      }
    refreshToolbarState()
  }

  private func refreshToolbarState() {
    let session = workspace.selectedSession
    backToolbarItem?.isEnabled = session?.canGoBack == true
    forwardToolbarItem?.isEnabled = session?.canGoForward == true

    let isLoading = session?.isLoading == true
    reloadToolbarItem?.image = toolbarImage(
      named: isLoading ? "xmark" : "arrow.clockwise",
      description: isLoading ? "Stop" : "Reload")
    reloadToolbarItem?.label = isLoading ? "Stop" : "Reload"
    reloadToolbarItem?.paletteLabel = isLoading ? "Stop" : "Reload"
    reloadToolbarItem?.toolTip = isLoading ? "Stop" : "Reload"
    reloadToolbarItem?.isEnabled = session != nil
    updateToolbarSectionVisibility()
  }

  private func updateToolbarSectionVisibility() {
    let isCollapsed = sidebarItem.isCollapsed
    let toolbarItems = toolbar?.items ?? []
    let flexibleSpace = toolbarItems.first {
      $0.itemIdentifier == .flexibleSpace
    }
    let spacingItems = toolbarItems.filter {
      $0.itemIdentifier == .space
    }
    let trackingSeparator = toolbarItems.first {
      $0.itemIdentifier == ToolbarID.trackingSeparator
    }

    newTabToolbarItem?.isHidden = isCollapsed
    flexibleSpace?.isHidden = isCollapsed
    trackingSeparator?.isHidden = isCollapsed
    // The first fixed space separates Show Sidebar from navigation while
    // collapsed. The second one always keeps navigation apart from Address.
    if !spacingItems.isEmpty {
      spacingItems[0].isHidden = !isCollapsed
    }
    if spacingItems.count > 1 {
      spacingItems[1].isHidden = false
    }

    if let sidebarToolbarItem {
      let label = isCollapsed ? "Show Sidebar" : "Hide Sidebar"
      sidebarToolbarItem.label = label
      sidebarToolbarItem.paletteLabel = label
      sidebarToolbarItem.toolTip = label
    }
  }

  private func makeButtonItem(
    identifier: NSToolbarItem.Identifier,
    label: String,
    symbol: String,
    action: Selector
  ) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    item.toolTip = label
    item.image = toolbarImage(named: symbol, description: label)
    item.isBordered = true
    item.target = self
    item.action = action
    return item
  }

  private func toolbarImage(named symbol: String, description: String) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    return NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: description
    )?.withSymbolConfiguration(configuration)
  }

  private func makeAddressItem() -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: ToolbarID.address)
    item.label = "Address"
    item.paletteLabel = "Address"

    let hostingView = NSHostingView(rootView: ToolbarAddressFieldView(workspace: workspace))
    hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 36)
    hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingView.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      hostingView.heightAnchor.constraint(equalToConstant: 36),
    ])
    // NSToolbarItem's view constraints establish the minimum, but AppKit does
    // not stretch an NSHostingView beyond its fitting width without a maximum.
    // These legacy sizing properties remain the native way to make this custom
    // item absorb the remaining toolbar width.
    item.minSize = NSSize(width: 240, height: 36)
    item.maxSize = NSSize(width: 10_000, height: 36)
    item.view = hostingView
    return item
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .flexibleSpace,
      ToolbarID.newTab,
      ToolbarID.toggleSidebar,
      ToolbarID.trackingSeparator,
      .space,
      ToolbarID.back,
      ToolbarID.forward,
      ToolbarID.reload,
      .space,
      ToolbarID.address,
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case ToolbarID.newTab:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "New Tab",
        symbol: "plus.square.on.square",
        action: #selector(createTab(_:)))
      newTabToolbarItem = item
      return item
    case ToolbarID.toggleSidebar:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar",
        symbol: "sidebar.left",
        action: #selector(toggleSidebarAction(_:)))
      sidebarToolbarItem = item
      return item
    case ToolbarID.trackingSeparator:
      return NSTrackingSeparatorToolbarItem(
        identifier: itemIdentifier,
        splitView: splitView,
        dividerIndex: 0)
    case ToolbarID.back:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "Back",
        symbol: "chevron.backward",
        action: #selector(goBack(_:)))
      backToolbarItem = item
      return item
    case ToolbarID.forward:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "Forward",
        symbol: "chevron.forward",
        action: #selector(goForward(_:)))
      forwardToolbarItem = item
      return item
    case ToolbarID.reload:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "Reload",
        symbol: "arrow.clockwise",
        action: #selector(reloadOrStop(_:)))
      reloadToolbarItem = item
      refreshToolbarState()
      return item
    case ToolbarID.address:
      return makeAddressItem()
    default:
      // AppKit creates the standard toggle-sidebar item itself.
      return nil
    }
  }

  @objc private func createTab(_ sender: NSToolbarItem) {
    workspace.createTab(url: nil)
  }

  @objc private func toggleSidebarAction(_ sender: NSToolbarItem) {
    super.toggleSidebar(sender)
  }

  @objc private func goBack(_ sender: NSToolbarItem) {
    workspace.selectedSession?.goBack()
  }

  @objc private func goForward(_ sender: NSToolbarItem) {
    workspace.selectedSession?.goForward()
  }

  @objc private func reloadOrStop(_ sender: NSToolbarItem) {
    workspace.selectedSession?.reloadOrStop()
  }
}

private struct BrowserShellContentView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    ZStack {
      BrowserSurfaceView(manager: workspace.sessionManager)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let session = workspace.selectedSession, session.rendererCrashed {
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
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct ToolbarAddressFieldView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    Group {
      if let session = workspace.selectedSession {
        addressField(for: session)
      } else {
        Color.clear
          .accessibilityHidden(true)
      }
    }
    .frame(minWidth: 240, maxWidth: .infinity)
    .frame(height: 36)
  }

  private func addressField(for session: BrowserSession) -> some View {
    HStack(spacing: 7) {
      Image(systemName: "globe")
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(Color.secondary.opacity(0.88))
        .frame(width: 14)
        .allowsHitTesting(false)

      AddressField(
        model: session.addressField,
        onChange: { session.addressField.userChangedText($0) },
        onSubmit: { session.submitAddressField() },
        onEscape: { session.cancelAddressEditing() },
        onFocusChange: { focused in
          interaction.isFocused = focused
          session.addressFieldFocusChanged(focused)
        }
      )
      .frame(minWidth: 240, maxWidth: .infinity, minHeight: 20, idealHeight: 22)
      .layoutPriority(1)
      .contentShape(Rectangle())
      .allowsHitTesting(true)
    }
    .padding(.horizontal, 8)
    .frame(minWidth: 240, maxWidth: .infinity)
    .frame(height: 36)
    .browserAddressFieldSurface(cornerRadius: 18)
    .overlay {
      if interaction.isFocused || session.addressField.isEditing {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressField)) {
      notification in
      guard (notification.object as? BrowserSession) === session else { return }
      NotificationCenter.default.post(
        name: .browserAddressFieldShouldFocus,
        object: session.addressField)
    }
  }
}
