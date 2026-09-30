//
//  BrowserToolbarController.swift
//  NativeBrowser
//
//  One stable native toolbar item hosts all page controls. Browser, window,
//  sidebar and focus events each trigger a layout from the current geometry;
//  none of those events changes the toolbar item's own width or position.
//

import AppKit
import Combine
import SwiftUI

@MainActor
private final class AddressOverlayHostingView: NSHostingView<ToolbarAddressFieldView> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    let focused = rootView.interaction.isFocused
    let rows = focused ? rootView.autocomplete.suggestions.count : 0
    let width = bounds.width * (focused ? 1
      : AddressCapsuleLayout.unfocusedWidthRatio / AddressCapsuleLayout.focusedWidthRatio)
    let height = AddressCapsuleLayout.panelHeight(rowCount: rows)
    let rect = NSRect(x: (bounds.width - width) / 2,
                      y: isFlipped ? 0 : bounds.height - height, width: width, height: height)
    guard rect.contains(local) else { return nil }
    return super.hitTest(point)
  }
}

@MainActor
private final class ToolbarChromeView: NSView {
  private let sidebarButton: NSButton
  private let sidebarGlass = NSGlassEffectView()
  private let navigationGroup = NSGlassEffectView()
  private let navigationContent = NSView()
  private let backButton: NSButton
  private let forwardButton: NSButton
  private let addressView: NSHostingView<ToolbarAddressFieldView>
  private var showsAddress = true

  init(
    sidebarButton: NSButton,
    backButton: NSButton,
    forwardButton: NSButton,
    addressView: NSHostingView<ToolbarAddressFieldView>
  ) {
    self.sidebarButton = sidebarButton
    self.backButton = backButton
    self.forwardButton = forwardButton
    self.addressView = addressView
    super.init(frame: NSRect(x: 0, y: 0, width: 1, height: AddressCapsuleLayout.height))

    sidebarGlass.style = .regular
    sidebarGlass.cornerRadius = AddressCapsuleLayout.cornerRadius
    if #available(macOS 27.0, *) {
      sidebarGlass.effectIsInteractive = true
    }
    sidebarButton.frame = NSRect(x: 0, y: 0,
                                 width: AddressCapsuleLayout.height,
                                 height: AddressCapsuleLayout.height)
    sidebarButton.autoresizingMask = [.width, .height]
    sidebarGlass.contentView = sidebarButton

    navigationGroup.style = .regular
    navigationGroup.cornerRadius = AddressCapsuleLayout.cornerRadius
    if #available(macOS 27.0, *) {
      navigationGroup.effectIsInteractive = true
    }
    navigationContent.frame = NSRect(x: 0, y: 0,
                                     width: 2 + 2 * AddressCapsuleLayout.height,
                                     height: AddressCapsuleLayout.height)
    navigationContent.autoresizingMask = [.width, .height]
    navigationGroup.contentView = navigationContent

    addSubview(sidebarGlass)
    addSubview(navigationGroup)
    navigationContent.addSubview(backButton)
    navigationContent.addSubview(forwardButton)
    // Mounted above the content view rather than inside the 36-point toolbar.
    // The same native field stays mounted while its unified surface expands.

    let height = AddressCapsuleLayout.height
    backButton.frame = NSRect(x: 1, y: 0, width: height, height: height)
    forwardButton.frame = NSRect(x: 1 + height, y: 0, width: height, height: height)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: AddressCapsuleLayout.height)
  }

  func setAddressVisible(_ visible: Bool) {
    showsAddress = visible
    addressView.isHidden = !visible
  }

  func setSidebarCollapsed(_ collapsed: Bool) {
    let title = collapsed ? "Show Sidebar" : "Hide Sidebar"
    sidebarButton.toolTip = title
    sidebarButton.setAccessibilityLabel(title)
  }

  func setNavigationState(
    canGoBack: Bool,
    canGoForward: Bool,
    hasSession: Bool
  ) {
    backButton.isEnabled = hasSession && canGoBack
    forwardButton.isEnabled = hasSession && canGoForward
  }

  func applyLayout(
    browserRect: NSRect,
    trafficLightsRight: CGFloat
  ) {
    guard browserRect.width > 0 else { return }
    let height = AddressCapsuleLayout.height
    let y = (bounds.height - height) / 2
    let sidebarLeft = max(trafficLightsRight + 10, browserRect.minX - height - 10)
    let navigationLeft = max(browserRect.minX + 7, sidebarLeft + height + 10)
    // Keep the host at its maximum width. SwiftUI animates the capsule inside
    // it so the native glass is never clipped by the host's rectangular bounds.
    let addressWidth = browserRect.width * AddressCapsuleLayout.focusedWidthRatio
    let addressLeft = browserRect.midX - addressWidth / 2

    setFrame(NSRect(x: sidebarLeft, y: y, width: height, height: height),
             on: sidebarGlass)
    setFrame(NSRect(x: navigationLeft, y: y, width: 2 + 2 * height, height: height),
             on: navigationGroup)
    if let contentView = window?.contentView?.superview {
      if addressView.superview !== contentView { contentView.addSubview(addressView, positioned: .above, relativeTo: nil) }
      let anchor = convert(NSRect(x: addressLeft, y: y, width: addressWidth, height: height), to: contentView)
      let panelHeight = AddressCapsuleLayout.maximumHeight
      let originY = contentView.isFlipped ? anchor.minY : anchor.maxY - panelHeight
      addressView.isHidden = !showsAddress
      setFrame(NSRect(x: anchor.minX, y: originY, width: addressWidth, height: panelHeight), on: addressView)
    }
  }

  private func setFrame(_ frame: NSRect, on view: NSView) {
    if view.frame != frame { view.frame = frame }
  }
}

@MainActor
final class BrowserToolbarController: NSObject, NSToolbarDelegate {
  private enum ToolbarID {
    static let chrome = NSToolbarItem.Identifier("cio.page-controls")
    static let sectionPlaceholder = NSToolbarItem.Identifier("cio.section-toolbar-placeholder")
  }

  private enum ToolbarEvent {
    case geometryChanged
    case sidebarChanged
    case sessionChanged
    case addressFocusChanged(BrowserSession, Bool)
    case addressFocusRequested(BrowserSession)
    case addressReloadOrStop(BrowserSession)
  }

  private let workspace: BrowserWorkspaceStore
  private let addressAutocomplete: AddressAutocompleteModel
  private let browserView: NSView
  private let isSidebarCollapsed: () -> Bool
  private let onSidebarToggle: () -> Void
  private weak var window: NSWindow?
  private var toolbar: NSToolbar?
  private var chromeView: ToolbarChromeView?
  private var browserFrameObservation: AnyCancellable?
  private var chromeFrameObservation: AnyCancellable?
  private var windowResizeObservation: AnyCancellable?
  private var workspaceObservation: AnyCancellable?
  private var selectedSessionObservations = Set<AnyCancellable>()
  private weak var observedSession: BrowserSession?
  private let addressPresentation = BrowserInteractionState()
  private var addressFocusRequestObservation: AnyCancellable?

  init(
    workspace: BrowserWorkspaceStore,
    history: HistoryService,
    browserView: NSView,
    isSidebarCollapsed: @escaping () -> Bool,
    onSidebarToggle: @escaping () -> Void
  ) {
    self.workspace = workspace
    self.addressAutocomplete = AddressAutocompleteModel(history: history)
    self.browserView = browserView
    self.isSidebarCollapsed = isSidebarCollapsed
    self.onSidebarToggle = onSidebarToggle
    super.init()
    browserView.postsFrameChangedNotifications = true
    browserFrameObservation = NotificationCenter.default.publisher(
      for: NSView.frameDidChangeNotification,
      object: browserView
    ).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.handle(.geometryChanged) }
    }
    observeWorkspace()
    addressFocusRequestObservation = NotificationCenter.default.publisher(
      for: .browserFocusAddressField
    ).sink { [weak self] notification in
      MainActor.assumeIsolated {
        guard let session = notification.object as? BrowserSession else { return }
        self?.handle(.addressFocusRequested(session))
      }
    }
    bindSelectedSession(workspace.selectedSession)
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
    if window.toolbar !== toolbar { window.toolbar = toolbar }
    toolbar?.isVisible = true

    windowResizeObservation = NotificationCenter.default.publisher(
      for: NSWindow.didResizeNotification,
      object: window
    ).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.handle(.geometryChanged) }
    }
    setSpaceControlsVisible(showsSpaceToolbar)
    bindSelectedSession(workspace.selectedSession)
    updateSidebarState()
  }

  func setSpaceControlsVisible(_ visible: Bool) {
    chromeView?.setAddressVisible(visible)
    toolbar?.items.forEach { item in
      item.isHidden = item.itemIdentifier == ToolbarID.sectionPlaceholder
        ? visible : !visible
    }
    handle(.geometryChanged)
  }

  func updateSidebarState() {
    handle(.sidebarChanged)
  }

  func browserGeometryDidChange() {
    handle(.geometryChanged)
  }

  private func handle(_ event: ToolbarEvent) {
    switch event {
    case .sidebarChanged:
      chromeView?.setSidebarCollapsed(isSidebarCollapsed())
    case .sessionChanged:
      if observedSession !== workspace.selectedSession, addressPresentation.isFocused {
        addressAutocomplete.end()
        addressPresentation.isFocused = false
        window?.makeFirstResponder(nil)
        observedSession?.addressFieldFocusChanged(false)
        workspace.selectedSession?.focusPage()
      }
      bindSelectedSession(workspace.selectedSession)
    case .addressFocusChanged(let session, let focused):
      guard workspace.selectedSession === session else { return }
      addressPresentation.isFocused = focused
      session.addressFieldFocusChanged(focused)
    case .addressFocusRequested(let session):
      guard workspace.selectedSession === session else { return }
      NotificationCenter.default.post(
        name: .browserAddressFieldShouldFocus,
        object: session.addressField)
    case .addressReloadOrStop(let session):
      guard workspace.selectedSession === session else { return }
      session.reloadOrStop()
    case .geometryChanged:
      break
    }
    applyCurrentLayout()
  }

  private func applyCurrentLayout() {
    guard let window,
          let chromeView,
          chromeView.window === window,
          browserView.window === window,
          let zoomButton = window.standardWindowButton(.zoomButton)
    else { return }

    let browserRect = browserView.convert(browserView.bounds, to: chromeView)
    let trafficLightsRight = zoomButton.convert(
      NSPoint(x: zoomButton.bounds.maxX, y: 0), to: chromeView).x
    chromeView.applyLayout(
      browserRect: browserRect,
      trafficLightsRight: trafficLightsRight)
  }

  private func observeWorkspace() {
    workspaceObservation = workspace.objectWillChange
      .sink { [weak self] _ in
        // objectWillChange is sent before selectedSession changes.
        DispatchQueue.main.async { [weak self] in
          MainActor.assumeIsolated { self?.refreshSelectedSessionObservation() }
        }
      }
  }

  private func refreshSelectedSessionObservation() {
    handle(.sessionChanged)
  }

  private func bindSelectedSession(_ session: BrowserSession?) {
    guard let session else {
      selectedSessionObservations.removeAll()
      observedSession = nil
      applyNavigationToolbarState(
        canGoBack: false, canGoForward: false, hasSession: false)
      return
    }

    if observedSession !== session {
      selectedSessionObservations.removeAll()
      observedSession = session
      Publishers.CombineLatest(
        session.$canGoBack,
        session.$canGoForward
      )
      .receive(on: RunLoop.main)
      .sink { [weak self, weak session] canGoBack, canGoForward in
        MainActor.assumeIsolated {
          guard let self, let session, self.observedSession === session else { return }
          self.applyNavigationToolbarState(
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            hasSession: true)
        }
      }
      .store(in: &selectedSessionObservations)
    }

    applyNavigationToolbarState(
      canGoBack: session.canGoBack,
      canGoForward: session.canGoForward,
      hasSession: true)
  }

  private func applyNavigationToolbarState(
    canGoBack: Bool,
    canGoForward: Bool,
    hasSession: Bool
  ) {
    chromeView?.setNavigationState(
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      hasSession: hasSession)
  }

  private func toolbarImage(named symbol: String, description: String) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    return NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: description
    )?.withSymbolConfiguration(configuration)
  }

  private func makeButton(
    label: String,
    symbol: String,
    action: Selector
  ) -> NSButton {
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
    button.bezelStyle = .toolbar
    button.isBordered = true
    button.showsBorderOnlyWhileMouseInside = true
    button.title = ""
    button.image = toolbarImage(named: symbol, description: label)
    button.imagePosition = .imageOnly
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.target = self
    button.action = action
    return button
  }

  private func makeChromeItem() -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: ToolbarID.chrome)
    item.label = "Page Controls"
    item.paletteLabel = "Page Controls"
    item.isBordered = false

    let sidebarButton = makeButton(
      label: "Hide Sidebar", symbol: "sidebar.left",
      action: #selector(handleSidebarToggle(_:)))
    let backButton = makeButton(
      label: "Back", symbol: "chevron.backward", action: #selector(goBack(_:)))
    let forwardButton = makeButton(
      label: "Forward", symbol: "chevron.forward", action: #selector(goForward(_:)))
    let addressView = AddressOverlayHostingView(rootView: ToolbarAddressFieldView(
      workspace: workspace,
      interaction: addressPresentation,
      autocomplete: addressAutocomplete,
      onFocusChange: { [weak self] session, focused in
        self?.handle(.addressFocusChanged(session, focused))
      },
      onReloadOrStop: { [weak self] session in
        self?.handle(.addressReloadOrStop(session))
      }))
    addressView.safeAreaRegions = []
    let view = ToolbarChromeView(
      sidebarButton: sidebarButton,
      backButton: backButton,
      forwardButton: forwardButton,
      addressView: addressView)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
      view.heightAnchor.constraint(equalToConstant: AddressCapsuleLayout.height),
    ])
    // AppKit still uses these bounds to let one custom item occupy the
    // remaining toolbar width; its child frames never affect item sizing.
    item.minSize = NSSize(width: 1, height: AddressCapsuleLayout.height)
    item.maxSize = NSSize(width: 10_000, height: AddressCapsuleLayout.height)
    item.view = view
    chromeView = view
    view.postsFrameChangedNotifications = true
    chromeFrameObservation = NotificationCenter.default.publisher(
      for: NSView.frameDidChangeNotification,
      object: view
    ).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.handle(.geometryChanged) }
    }
    return item
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [ToolbarID.chrome, ToolbarID.sectionPlaceholder]
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
    case ToolbarID.sectionPlaceholder:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.isBordered = false
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 36))
      view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: 1),
        view.heightAnchor.constraint(equalToConstant: 36),
      ])
      item.view = view
      return item
    case ToolbarID.chrome:
      return makeChromeItem()
    default:
      return nil
    }
  }

  @objc private func handleSidebarToggle(_ sender: NSButton) {
    onSidebarToggle()
  }

  @objc private func goBack(_ sender: NSButton) {
    workspace.selectedSession?.goBack()
  }

  @objc private func goForward(_ sender: NSButton) {
    workspace.selectedSession?.goForward()
  }

}
