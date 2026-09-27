//
//  BrowserToolbarController.swift
//  NativeBrowser
//
//  Native Space toolbar and page controls. The shell supplies layout and
//  sidebar actions without owning individual toolbar items.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class BrowserToolbarController: NSObject, NSToolbarDelegate {
  private enum ToolbarID {
    static let showSidebar = NSToolbarItem.Identifier("cio.show-sidebar")
    static let back = NSToolbarItem.Identifier("cio.back")
    static let forward = NSToolbarItem.Identifier("cio.forward")
    static let reload = NSToolbarItem.Identifier("cio.reload")
    static let address = NSToolbarItem.Identifier("cio.address")
    static let leadingSpacer = NSToolbarItem.Identifier("cio.sidebar-leading-spacer")
  }

  private let workspace: BrowserWorkspaceStore
  private let browserView: NSView
  private let isSidebarCollapsed: () -> Bool
  private let onSidebarToggle: () -> Void
  private weak var window: NSWindow?
  private var toolbar: NSToolbar?
  private weak var showSidebarToolbarItem: NSToolbarItem?
  private var sidebarButton: NSButton?
  private var leadingSpacerToolbarItem: NSToolbarItem?
  private var leadingSpacerWidth: CGFloat = 0
  private var browserFrameObservation: AnyCancellable?
  private weak var backToolbarItem: NSToolbarItem?
  private weak var forwardToolbarItem: NSToolbarItem?
  private weak var reloadToolbarItem: NSToolbarItem?
  private var workspaceObservation: AnyCancellable?
  private var selectedSessionObservations = Set<AnyCancellable>()
  private weak var observedSession: BrowserSession?

  init(
    workspace: BrowserWorkspaceStore,
    browserView: NSView,
    isSidebarCollapsed: @escaping () -> Bool,
    onSidebarToggle: @escaping () -> Void
  ) {
    self.workspace = workspace
    self.browserView = browserView
    self.isSidebarCollapsed = isSidebarCollapsed
    self.onSidebarToggle = onSidebarToggle
    super.init()
    browserView.postsFrameChangedNotifications = true
    browserFrameObservation = NotificationCenter.default.publisher(
      for: NSView.frameDidChangeNotification,
      object: browserView
    ).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.updateSidebarButtonPosition() }
    }
    observeWorkspace()
    bindSelectedSession(workspace.selectedSession)
  }

  func setVisible(_ visible: Bool) {
    toolbar?.isVisible = visible
  }

  func install(in window: NSWindow, showsSpaceToolbar: Bool) {
    self.window = window

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
    toolbar?.isVisible = showsSpaceToolbar
    captureToolbarPresentationItems()
    bindSelectedSession(workspace.selectedSession)
    updateSidebarState()
    DispatchQueue.main.async { [weak self] in self?.updateSidebarButtonPosition() }
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

  func updateSidebarState() {
    let isCollapsed = isSidebarCollapsed()
    captureToolbarPresentationItems()
    let title = isCollapsed ? "Show Sidebar" : "Hide Sidebar"
    showSidebarToolbarItem?.label = title
    showSidebarToolbarItem?.paletteLabel = title
    showSidebarToolbarItem?.toolTip = title
    sidebarButton?.toolTip = title
    sidebarButton?.setAccessibilityLabel(title)
  }

  func insertLeadingSpacer() {
    guard let toolbar,
          !toolbar.items.contains(where: { $0.itemIdentifier == ToolbarID.leadingSpacer })
    else { return }
    toolbar.insertItem(withItemIdentifier: ToolbarID.leadingSpacer, at: 0)
    captureToolbarPresentationItems()
    updateSidebarButtonPosition()
  }

  func removeLeadingSpacer() {
    guard let toolbar,
          let index = toolbar.items.firstIndex(where: {
            $0.itemIdentifier == ToolbarID.leadingSpacer
          })
    else { return }
    toolbar.removeItem(at: index)
    leadingSpacerWidth = 0
    leadingSpacerToolbarItem = nil
  }

  func updateSidebarButtonPosition() {
    guard let window,
          let button = sidebarButton,
          let spacer = leadingSpacerToolbarItem,
          let zoomButton = window.standardWindowButton(.zoomButton)
    else { return }

    let browserLeft = browserView.convert(.zero, to: nil).x
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
      let title = isSidebarCollapsed() ? "Show Sidebar" : "Hide Sidebar"
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = title
      item.paletteLabel = title
      item.toolTip = title
      item.isBordered = true
      let button = NSButton(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
      button.bezelStyle = .glass
      button.title = ""
      button.image = toolbarImage(named: "sidebar.left", description: title)
      button.imagePosition = .imageOnly
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 36),
        button.heightAnchor.constraint(equalToConstant: 36),
      ])
      button.toolTip = title
      button.setAccessibilityLabel(title)
      button.target = self
      button.action = #selector(handleSidebarToggle(_:))
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

  @objc private func handleSidebarToggle(_ sender: NSButton) {
    onSidebarToggle()
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
