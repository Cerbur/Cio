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
    static let showSidebar = NSToolbarItem.Identifier("cio.show-sidebar")
    static let back = NSToolbarItem.Identifier("cio.back")
    static let forward = NSToolbarItem.Identifier("cio.forward")
    static let reload = NSToolbarItem.Identifier("cio.reload")
    static let address = NSToolbarItem.Identifier("cio.address")
    static let trackingSeparator = NSToolbarItem.Identifier("cio.sidebar-tracking-separator")
  }

  private let runtime: ApplicationRuntime
  private let workspace: BrowserWorkspaceStore
  private let sidebarChromeLayout = SidebarChromeLayout()
  private let sidebarItem: NSSplitViewItem
  private let browserItem: NSSplitViewItem

  private var toolbar: NSToolbar?
  private weak var showSidebarToolbarItem: NSToolbarItem?
  private weak var leadingFlexibleSpaceToolbarItem: NSToolbarItem?
  private weak var trackingSeparatorToolbarItem: NSToolbarItem?
  private weak var collapsedToggleNavSpacerItem: NSToolbarItem?
  private weak var navAddressSpacerItem: NSToolbarItem?
  private weak var backToolbarItem: NSToolbarItem?
  private weak var forwardToolbarItem: NSToolbarItem?
  private weak var reloadToolbarItem: NSToolbarItem?
  private var workspaceObservation: AnyCancellable?
  private var selectedSessionObservations = Set<AnyCancellable>()
  private weak var observedSession: BrowserSession?
  private var sidebarCollapseObservation: NSKeyValueObservation?
  private var didRestoreSidebarWidth = false

  init(runtime: ApplicationRuntime) {
    self.runtime = runtime
    workspace = runtime.workspaceStore

    let sidebarRootView = AnyView(
      TabSidebarView(workspace: runtime.workspaceStore)
        .environmentObject(runtime)
        .environmentObject(sidebarChromeLayout)
        .frame(maxHeight: .infinity))
    let sidebarHostingController = NSHostingController(rootView: sidebarRootView)
    let browserHostingController = NSHostingController(
      rootView: BrowserShellContentView(workspace: runtime.workspaceStore))

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.minimumThickness = BrowserLayout.sidebarMinimumWidth
    sidebarItem.maximumThickness = BrowserLayout.sidebarMaximumWidth
    sidebarItem.allowsFullHeightLayout = true
    sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    self.sidebarItem = sidebarItem

    let browserItem = NSSplitViewItem(viewController: browserHostingController)
    self.browserItem = browserItem

    super.init(nibName: nil, bundle: nil)

    splitView.isVertical = true
    sidebarChromeLayout.splitView = splitView
    sidebarChromeLayout.shellController = self
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
      splitView.setPosition(
        min(max(desired, BrowserLayout.sidebarMinimumWidth), BrowserLayout.sidebarMaximumWidth),
        ofDividerAt: 0)
    }
    installToolbarIfNeeded()
    updateSidebarChromeLayout()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateSidebarChromeLayout()
  }

  private func topChromeOverlap(in window: NSWindow) -> CGFloat {
    guard let contentView = window.contentView else { return 0 }
    let contentFrame = contentView.convert(contentView.bounds, to: nil)
    return max(0, contentFrame.maxY - window.contentLayoutRect.maxY)
  }

  private func updateSidebarChromeLayout() {
    guard let window = view.window else { return }
    sidebarChromeLayout.update(topInset: topChromeOverlap(in: window))
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
    captureToolbarPresentationItems()
    bindSelectedSession(workspace.selectedSession)
    applyToolbarLayout(forSidebarCollapsed: sidebarItem.isCollapsed)
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
    leadingFlexibleSpaceToolbarItem = items.first {
      $0.itemIdentifier == .flexibleSpace
    }
    trackingSeparatorToolbarItem = items.first {
      $0.itemIdentifier == ToolbarID.trackingSeparator
    }
    backToolbarItem = items.first { $0.itemIdentifier == ToolbarID.back }
    forwardToolbarItem = items.first { $0.itemIdentifier == ToolbarID.forward }
    reloadToolbarItem = items.first { $0.itemIdentifier == ToolbarID.reload }
    collapsedToggleNavSpacerItem = sidebarItem.isCollapsed
      ? toolbarItem(immediatelyAfter: ToolbarID.showSidebar, withIdentifier: .space, in: toolbar)
      : nil
    navAddressSpacerItem = toolbarItem(
      immediatelyAfter: ToolbarID.reload,
      withIdentifier: .space,
      in: toolbar)
  }

  private func toolbarItem(
    immediatelyAfter anchorIdentifier: NSToolbarItem.Identifier,
    withIdentifier expectedIdentifier: NSToolbarItem.Identifier,
    in toolbar: NSToolbar
  ) -> NSToolbarItem? {
    let items = toolbar.items
    guard let anchorIndex = items.firstIndex(where: {
      $0.itemIdentifier == anchorIdentifier
    }) else { return nil }
    let followingIndex = items.index(after: anchorIndex)
    guard followingIndex < items.endIndex else { return nil }
    let item = items[followingIndex]
    return item.itemIdentifier == expectedIdentifier ? item : nil
  }

  private var expandedToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
    [
      .flexibleSpace,
      ToolbarID.trackingSeparator,
      ToolbarID.back,
      ToolbarID.forward,
      ToolbarID.reload,
      .space,
      ToolbarID.address,
    ]
  }

  private var collapsedToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
    [
      ToolbarID.showSidebar,
      .space,
      ToolbarID.back,
      ToolbarID.forward,
      ToolbarID.reload,
      .space,
      ToolbarID.address,
    ]
  }

  private func applyToolbarLayout(forSidebarCollapsed isCollapsed: Bool) {
    guard let toolbar else { return }

    let expectedIdentifiers = isCollapsed
      ? collapsedToolbarItemIdentifiers
      : expandedToolbarItemIdentifiers
    if toolbar.items.map(\.itemIdentifier) != expectedIdentifiers {
      if isCollapsed {
        applyCollapsedToolbarLayout(in: toolbar)
      } else {
        applyExpandedToolbarLayout(in: toolbar)
      }
    }

    captureToolbarPresentationItems()
    assert(
      toolbar.items.map(\.itemIdentifier) == expectedIdentifiers,
      "Toolbar item order did not reconcile to the requested sidebar layout")
  }

  private func applyCollapsedToolbarLayout(in toolbar: NSToolbar) {
    removeExpandedToolbarSection(from: toolbar)
    ensureToolbarItem(ToolbarID.showSidebar, at: 0, in: toolbar)
    ensureCollapsedToggleNavSpacer(in: toolbar)
  }

  private func applyExpandedToolbarLayout(in toolbar: NSToolbar) {
    removeCollapsedLeadingItems(from: toolbar)
    removeExpandedToolbarSection(from: toolbar)

    let navigationIndex = toolbar.items.firstIndex {
      $0.itemIdentifier == ToolbarID.back
    } ?? toolbar.items.endIndex
    let expandedSection: [NSToolbarItem.Identifier] = [
      .flexibleSpace,
      ToolbarID.trackingSeparator,
    ]
    for (offset, identifier) in expandedSection.enumerated() {
      toolbar.insertItem(withItemIdentifier: identifier, at: navigationIndex + offset)
    }
  }

  private func removeExpandedToolbarSection(from toolbar: NSToolbar) {
    removeToolbarItems(
      withIdentifiers: [
        .flexibleSpace,
        ToolbarID.trackingSeparator,
      ],
      from: toolbar)
    leadingFlexibleSpaceToolbarItem = nil
    trackingSeparatorToolbarItem = nil
  }

  private func removeToolbarItems(
    withIdentifiers identifiers: Set<NSToolbarItem.Identifier>,
    from toolbar: NSToolbar
  ) {
    let indices = toolbar.items.enumerated().compactMap { index, item in
      identifiers.contains(item.itemIdentifier) ? index : nil
    }
    for index in indices.reversed() {
      toolbar.removeItem(at: index)
    }
  }

  private func ensureToolbarItem(
    _ identifier: NSToolbarItem.Identifier,
    at targetIndex: Int,
    in toolbar: NSToolbar
  ) {
    let indices = toolbar.items.enumerated().compactMap { index, item in
      item.itemIdentifier == identifier ? index : nil
    }
    if indices.count == 1, indices[0] == targetIndex { return }

    for index in indices.reversed() {
      toolbar.removeItem(at: index)
    }
    if identifier == ToolbarID.showSidebar {
      showSidebarToolbarItem = nil
    }
    toolbar.insertItem(withItemIdentifier: identifier, at: min(targetIndex, toolbar.items.count))
  }

  private func ensureCollapsedToggleNavSpacer(in toolbar: NSToolbar) {
    guard let showIndex = toolbar.items.firstIndex(where: {
      $0.itemIdentifier == ToolbarID.showSidebar
    }) else { return }

    let spacerIndex = showIndex + 1
    if spacerIndex < toolbar.items.count,
       toolbar.items[spacerIndex].itemIdentifier == .space
    {
      collapsedToggleNavSpacerItem = toolbar.items[spacerIndex]
      return
    }

    toolbar.insertItem(withItemIdentifier: .space, at: spacerIndex)
    collapsedToggleNavSpacerItem = toolbar.items[spacerIndex]
  }

  private func removeCollapsedLeadingItems(from toolbar: NSToolbar) {
    var indices: [Int] = []
    if let spacer = collapsedToggleNavSpacerItem,
       let spacerIndex = toolbar.items.firstIndex(where: { $0 === spacer })
    {
      indices.append(spacerIndex)
    } else if let showIndex = toolbar.items.firstIndex(where: {
      $0.itemIdentifier == ToolbarID.showSidebar
    }), showIndex + 1 < toolbar.items.count,
      toolbar.items[showIndex + 1].itemIdentifier == .space
    {
      indices.append(showIndex + 1)
    }

    indices.append(contentsOf: toolbar.items.enumerated().compactMap { index, item in
      item.itemIdentifier == ToolbarID.showSidebar ? index : nil
    })
    for index in Set(indices).sorted(by: >) {
      toolbar.removeItem(at: index)
    }
    showSidebarToolbarItem = nil
    collapsedToggleNavSpacerItem = nil
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
      .flexibleSpace,
      ToolbarID.trackingSeparator,
      ToolbarID.back,
      ToolbarID.forward,
      ToolbarID.reload,
      .space,
      ToolbarID.address,
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar) + [ToolbarID.showSidebar]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case ToolbarID.showSidebar:
      let item = makeButtonItem(
        identifier: itemIdentifier,
        label: "Show Sidebar",
        symbol: "sidebar.left",
        action: #selector(toggleSidebarAction(_:)))
      showSidebarToolbarItem = item
      return item
    case ToolbarID.trackingSeparator:
      let item = NSTrackingSeparatorToolbarItem(
        identifier: itemIdentifier,
        splitView: splitView,
        dividerIndex: 0)
      trackingSeparatorToolbarItem = item
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
