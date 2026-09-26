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

private final class SeamlessSplitView: NSSplitView {
  override func drawDivider(in rect: NSRect) {}
}

private struct SidebarToolbarIcon: View {
  var body: some View {
    Image(systemName: "sidebar.left")
      .font(.system(size: 15, weight: .medium))
      .frame(width: 36, height: 36)
      .background(.regularMaterial, in: Circle())
      .overlay {
        Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
      }
  }
}

private final class SidebarToolbarView: NSHostingView<SidebarToolbarIcon> {
  var onActivate: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    onActivate?()
  }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49 {
      onActivate?()
    } else {
      super.keyDown(with: event)
    }
  }
}

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
    static let showSidebar = NSToolbarItem.Identifier("cio.show-sidebar")
    static let back = NSToolbarItem.Identifier("cio.back")
    static let forward = NSToolbarItem.Identifier("cio.forward")
    static let reload = NSToolbarItem.Identifier("cio.reload")
    static let address = NSToolbarItem.Identifier("cio.address")
    static let leadingSpacer = NSToolbarItem.Identifier("cio.sidebar-leading-spacer")
  }

  private let runtime: ApplicationRuntime
  private let workspace: BrowserWorkspaceStore
  private let sidebarChromeLayout = SidebarChromeLayout()
  private let railItem: NSSplitViewItem
  private let sidebarItem: NSSplitViewItem
  private let browserItem: NSSplitViewItem

  private var toolbar: NSToolbar?
  private weak var showSidebarToolbarItem: NSToolbarItem?
  private var sidebarButton: NSView?
  private var leadingSpacerToolbarItem: NSToolbarItem?
  private var leadingSpacerWidth: CGFloat = 0
  private var browserFrameObservation: AnyCancellable?
  private weak var backToolbarItem: NSToolbarItem?
  private weak var forwardToolbarItem: NSToolbarItem?
  private weak var reloadToolbarItem: NSToolbarItem?
  private var workspaceObservation: AnyCancellable?
  private var panelObservation: AnyCancellable?
  private var sidebarWasCollapsedBeforeLibrary = false
  private var wasShowingLibrary = false
  private var selectedSessionObservations = Set<AnyCancellable>()
  private weak var observedSession: BrowserSession?
  private var sidebarCollapseObservation: NSKeyValueObservation?
  private var didRestoreSidebarWidth = false
  private var expandedSidebarWidth = BrowserLayout.sidebarDefaultWidth

  init(runtime: ApplicationRuntime) {
    self.runtime = runtime
    workspace = runtime.workspaceStore

    let sidebarRootView = AnyView(
      TabSidebarView(workspace: runtime.workspaceStore)
        .environmentObject(sidebarChromeLayout)
        .frame(maxHeight: .infinity))
    let sidebarHostingController = NSHostingController(rootView: sidebarRootView)
    sidebarHostingController.view.wantsLayer = true
    sidebarHostingController.view.layer?.cornerRadius = 18
    sidebarHostingController.view.layer?.maskedCorners = [
      .layerMinXMinYCorner, .layerMinXMaxYCorner,
    ]
    sidebarHostingController.view.layer?.masksToBounds = true
    let railHostingController = NSHostingController(rootView: NavigationRail(runtime: runtime))
    let browserHostingController = NSHostingController(
      rootView: BrowserShellContentView(runtime: runtime, workspace: runtime.workspaceStore))

    let railItem = NSSplitViewItem(viewController: railHostingController)
    railItem.minimumThickness = BrowserLayout.railWidth
    railItem.maximumThickness = BrowserLayout.railWidth
    railItem.canCollapse = false
    self.railItem = railItem

    let sidebarItem = NSSplitViewItem(viewController: sidebarHostingController)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.minimumThickness = BrowserLayout.sidebarMinimumWidth
    sidebarItem.maximumThickness = BrowserLayout.sidebarMaximumWidth
    sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    self.sidebarItem = sidebarItem

    let browserItem = NSSplitViewItem(viewController: browserHostingController)
    self.browserItem = browserItem

    super.init(nibName: nil, bundle: nil)

    splitView = SeamlessSplitView()
    splitView.isVertical = true
    sidebarChromeLayout.splitView = splitView
    splitView.dividerStyle = .thin
    splitView.wantsLayer = true
    splitView.layer?.cornerRadius = 18
    splitView.layer?.masksToBounds = true
    addSplitViewItem(railItem)
    addSplitViewItem(sidebarItem)
    addSplitViewItem(browserItem)
    browserHostingController.view.postsFrameChangedNotifications = true
    browserFrameObservation = NotificationCenter.default.publisher(
      for: NSView.frameDidChangeNotification,
      object: browserHostingController.view
    ).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.updateSidebarButtonPosition() }
    }

  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeSidebarCollapse()
    observeWorkspace()
    observePanelSelection()
    bindSelectedSession(workspace.selectedSession)
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    // Configure full-size content before NSSplitViewController lays out its
    // full-height sidebar beneath the toolbar.
    installToolbarIfNeeded()
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
      splitView.setPosition(
        BrowserLayout.railWidth + expandedSidebarWidth,
        ofDividerAt: 1)
    }
    installToolbarIfNeeded()
    updateSidebarChromeLayout()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateSidebarChromeLayout()
    updateSidebarButtonPosition()
  }

  override func splitView(
    _ splitView: NSSplitView,
    shouldHideDividerAt dividerIndex: Int
  ) -> Bool {
    dividerIndex <= 1 || super.splitView(splitView, shouldHideDividerAt: dividerIndex)
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
    applyToolbarLayout(forSidebarCollapsed: sidebarItem.isCollapsed)
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
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    if window.toolbar !== toolbar {
      window.toolbar = toolbar
    }
    captureToolbarPresentationItems()
    bindSelectedSession(workspace.selectedSession)
    applyToolbarLayout(forSidebarCollapsed: sidebarItem.isCollapsed)
    DispatchQueue.main.async { [weak self] in self?.updateSidebarButtonPosition() }
  }

  private func observeSidebarCollapse() {
    sidebarCollapseObservation = sidebarItem.observe(
      \.isCollapsed,
      options: [.initial, .new]
    ) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.applyToolbarLayout(forSidebarCollapsed: self.sidebarItem.isCollapsed)
      }
    }
  }

  private func observeWorkspace() {
    workspaceObservation = workspace.objectWillChange
      .sink { [weak self] _ in
        // objectWillChange is pre-mutation for ObservableObject. Defer one
        // main-loop turn so selectedSession is read after the workspace change.
        DispatchQueue.main.async { [weak self] in
          MainActor.assumeIsolated {
            self?.refreshSelectedSessionObservation()
          }
        }
      }
  }

  private func refreshSelectedSessionObservation() {
    bindSelectedSession(workspace.selectedSession)
  }

  private func bindSelectedSession(_ session: BrowserSession?) {
    guard let session else {
      selectedSessionObservations.removeAll()
      observedSession = nil
      applyNavigationToolbarState(
        canGoBack: false,
        canGoForward: false,
        isLoading: false,
        hasSession: false)
      return
    }

    if observedSession !== session {
      selectedSessionObservations.removeAll()
      observedSession = session

      Publishers.CombineLatest3(
        session.$canGoBack,
        session.$canGoForward,
        session.$isLoading
      )
      .receive(on: RunLoop.main)
      .sink { [weak self, weak session] canGoBack, canGoForward, isLoading in
        MainActor.assumeIsolated {
          guard let self, let session, self.observedSession === session else { return }
          self.applyNavigationToolbarState(
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isLoading: isLoading,
            hasSession: true)
        }
      }
      .store(in: &selectedSessionObservations)
    }

    // Apply current values immediately when selected, without waiting for a
    // subsequent publisher event to correct the previous tab's toolbar state.
    applyNavigationToolbarState(
      canGoBack: session.canGoBack,
      canGoForward: session.canGoForward,
      isLoading: session.isLoading,
      hasSession: true)
  }

  private func applyNavigationToolbarState(
    canGoBack: Bool,
    canGoForward: Bool,
    isLoading: Bool,
    hasSession: Bool
  ) {
    backToolbarItem?.isEnabled = hasSession && canGoBack
    forwardToolbarItem?.isEnabled = hasSession && canGoForward
    reloadToolbarItem?.image = toolbarImage(
      named: isLoading ? "xmark" : "arrow.clockwise",
      description: isLoading ? "Stop" : "Reload")
    // Keep the item's measured width stable while a newly selected tab loads.
    // Only its icon and help text need to change between Reload and Stop.
    reloadToolbarItem?.label = "Reload"
    reloadToolbarItem?.paletteLabel = "Reload"
    reloadToolbarItem?.toolTip = isLoading ? "Stop" : "Reload"
    reloadToolbarItem?.isEnabled = hasSession
  }

  private func captureToolbarPresentationItems() {
    guard let toolbar else { return }
    let items = toolbar.items
    showSidebarToolbarItem = items.first { $0.itemIdentifier == ToolbarID.showSidebar }
    leadingSpacerToolbarItem = items.first { $0.itemIdentifier == ToolbarID.leadingSpacer }
    backToolbarItem = items.first { $0.itemIdentifier == ToolbarID.back }
    forwardToolbarItem = items.first { $0.itemIdentifier == ToolbarID.forward }
    reloadToolbarItem = items.first { $0.itemIdentifier == ToolbarID.reload }
  }

  private func applyToolbarLayout(forSidebarCollapsed isCollapsed: Bool) {
    captureToolbarPresentationItems()
    let title = isCollapsed ? "Show Sidebar" : "Hide Sidebar"
    showSidebarToolbarItem?.label = title
    showSidebarToolbarItem?.paletteLabel = title
    showSidebarToolbarItem?.toolTip = title
    sidebarButton?.toolTip = title
    sidebarButton?.setAccessibilityLabel(title)
  }

  private func insertLeadingSpacer() {
    guard let toolbar,
          !toolbar.items.contains(where: { $0.itemIdentifier == ToolbarID.leadingSpacer })
    else { return }
    toolbar.insertItem(withItemIdentifier: ToolbarID.leadingSpacer, at: 0)
    captureToolbarPresentationItems()
    updateSidebarButtonPosition()
  }

  private func removeLeadingSpacer() {
    guard let toolbar,
          let index = toolbar.items.firstIndex(where: {
            $0.itemIdentifier == ToolbarID.leadingSpacer
          })
    else { return }
    toolbar.removeItem(at: index)
    leadingSpacerWidth = 0
    leadingSpacerToolbarItem = nil
  }

  private func updateSidebarButtonPosition() {
    guard let window = view.window,
          let button = sidebarButton,
          let spacer = leadingSpacerToolbarItem,
          let zoomButton = window.standardWindowButton(.zoomButton)
    else { return }

    let browserLeft = browserItem.viewController.view.convert(.zero, to: nil).x
    let trafficLightsRight = zoomButton.convert(
      NSPoint(x: zoomButton.bounds.maxX, y: 0), to: nil).x
    let buttonLeft = button.convert(.zero, to: nil).x
    let targetLeft = max(trafficLightsRight + 10,
                         browserLeft - button.bounds.width - 10)
    let nextWidth = max(0, leadingSpacerWidth + targetLeft - buttonLeft)
    guard abs(nextWidth - leadingSpacerWidth) > 0.5 else { return }
    leadingSpacerWidth = nextWidth
    spacer.minSize = NSSize(width: nextWidth, height: 1)
    spacer.maxSize = NSSize(width: nextWidth, height: 1)
    spacer.view?.setFrameSize(NSSize(width: nextWidth, height: 1))
  }

  private func makeButtonItem(
    identifier: NSToolbarItem.Identifier,
    label: String,
    symbol: String,
    action: Selector,
    autovalidates: Bool = true
  ) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    item.toolTip = label
    item.image = toolbarImage(named: symbol, description: label)
    item.isBordered = true
    item.target = self
    item.action = action
    item.autovalidates = autovalidates
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
      ToolbarID.leadingSpacer,
      ToolbarID.showSidebar,
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
    case ToolbarID.leadingSpacer:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.isBordered = false
      item.view = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 1))
      item.minSize = NSSize(width: 0, height: 1)
      item.maxSize = NSSize(width: 0, height: 1)
      leadingSpacerToolbarItem = item
      return item
    case ToolbarID.showSidebar:
      let title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = title
      item.paletteLabel = title
      item.toolTip = title
      item.isBordered = false
      let button = SidebarToolbarView(rootView: SidebarToolbarIcon())
      button.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
      button.toolTip = title
      button.setAccessibilityRole(.button)
      button.setAccessibilityLabel(title)
      button.onActivate = { [weak self] in self?.handleSidebarToggle() }
      item.view = button
      item.minSize = button.frame.size
      item.maxSize = button.frame.size
      sidebarButton = button
      showSidebarToolbarItem = item
      return item
    case ToolbarID.back:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "Back",
        symbol: "chevron.backward",
        action: #selector(goBack(_:)),
        autovalidates: false)
      backToolbarItem = item
      return item
    case ToolbarID.forward:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "Forward",
        symbol: "chevron.forward",
        action: #selector(goForward(_:)),
        autovalidates: false)
      forwardToolbarItem = item
      return item
    case ToolbarID.reload:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "Reload",
        symbol: "arrow.clockwise",
        action: #selector(reloadOrStop(_:)),
        autovalidates: false)
      reloadToolbarItem = item
      return item
    case ToolbarID.address:
      return makeAddressItem()
    default:
      // AppKit creates the standard toggle-sidebar item itself.
      return nil
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
        insertLeadingSpacer()
        sidebarItem.animator().isCollapsed = false
      }
      let width = expandedSidebarWidth
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.splitView.setPosition(
          BrowserLayout.railWidth + self.splitView.dividerThickness + width,
          ofDividerAt: 1)
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
          self.removeLeadingSpacer()
        }
      }
    }
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
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct NavigationRail: View {
  @ObservedObject var runtime: ApplicationRuntime

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 2) {
        sectionButton("Space", symbol: "house.fill", panel: nil)
        sectionButton("History", symbol: "clock.arrow.circlepath", panel: .history)
        sectionButton("Downloads", symbol: "arrow.down.circle", panel: .downloads)
      }
      .padding(4)
      .browserChromeGlassSurface(in: Capsule())
      Spacer(minLength: 0)
    }
    .padding(.top, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }

  private func sectionButton(
    _ title: String,
    symbol: String,
    panel: ApplicationRuntime.InternalBrowserPanel?
  ) -> some View {
    let isSelected = runtime.presentedInternalPanel == panel
    return Button {
      switch panel {
      case .history: runtime.showHistory()
      case .downloads: runtime.showDownloads()
      case nil: runtime.presentedInternalPanel = nil
      }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
        .frame(width: 48, height: 48)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    .background {
      if isSelected {
        Capsule()
          .fill(Color.primary.opacity(0.11))
      }
    }
    .help(title)
    .accessibilityLabel(title)
    .accessibilityIdentifier("browser-section-\(panel?.rawValue ?? "space")")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
      TabFaviconView(pageURL: session.url ?? workspace.selectedTab?.url,
                     session: session, size: 16)
        .frame(width: 16, height: 16)
        .allowsHitTesting(false)
        .accessibilityHidden(true)

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
