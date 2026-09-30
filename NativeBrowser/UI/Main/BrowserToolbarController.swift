//
//  BrowserToolbarController.swift
//  NativeBrowser
//
//  Shell-owned toolbar with native window buttons and page controls. Its
//  height comes from the same metric as the navigation rail; AppKit no longer
//  adds an independent toolbar safe area above the Main View.
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
  private var trafficLights: [NSButton] = []
  private weak var trafficLightsWindow: NSWindow?

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
    super.init(frame: NSRect(x: 0, y: 0, width: 1, height: BrowserLayout.chromeThickness))

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
    // The field is a shell overlay, keeping the same native editor mounted
    // while its glass expands over the Main View.

    let height = AddressCapsuleLayout.height
    backButton.frame = NSRect(x: 1, y: 0, width: height, height: height)
    forwardButton.frame = NSRect(x: 1 + height, y: 0, width: height, height: height)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: BrowserLayout.chromeThickness)
  }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

  func installTrafficLights(in window: NSWindow) {
    guard trafficLightsWindow !== window else { return }
    trafficLightsWindow = window
    let controls: [(NSWindow.ButtonType, Selector, String)] = [
      (.closeButton, #selector(NSWindow.performClose(_:)), "Close"),
      (.miniaturizeButton, #selector(NSWindow.performMiniaturize(_:)), "Minimize"),
      (.zoomButton, #selector(NSWindow.toggleFullScreen(_:)), "Full Screen"),
    ]
    // AppKit can reclaim the window-owned titlebar buttons during relayout.
    // Its public factory supplies native buttons owned by this toolbar instead.
    trafficLights = controls.compactMap { type, action, label in
      guard let button = NSWindow.standardWindowButton(type, for: window.styleMask) else { return nil }
      button.target = window
      button.action = action
      button.setAccessibilityLabel(label)
      button.toolTip = label
      button.autoresizingMask = []
      addSubview(button)
      return button
    }
  }

  override func layout() {
    super.layout()
    layoutTrafficLights()
  }

  private func layoutTrafficLights() {
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window?.standardWindowButton(type)?.isHidden = true
    }
    let fullscreen = window?.styleMask.contains(.fullScreen) == true
    let frames = BrowserShellFrames.trafficLightFrames(
      sizes: trafficLights.map { $0.frame.size }, toolbarHeight: bounds.height)
    for (button, frame) in zip(trafficLights, frames) {
      button.isHidden = fullscreen
      button.frame = frame
    }
  }

  func setAddressVisible(_ visible: Bool) {
    showsAddress = visible
    addressView.isHidden = !visible
    sidebarGlass.isHidden = !visible
    navigationGroup.isHidden = !visible
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
    browserRect: NSRect
  ) {
    guard browserRect.width > 0 else { return }
    layoutTrafficLights()
    let trafficLightsRight = trafficLights.last?.frame.maxX ?? 0
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
    if let contentView = superview {
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
final class BrowserToolbarController: NSObject {
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
  private var chromeView: ToolbarChromeView?
  private var browserFrameObservation: AnyCancellable?
  private var windowObservations = Set<AnyCancellable>()
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

  /// Mounted as a sibling of Main View and navigation rail by the shell.
  var view: NSView {
    if let chromeView { return chromeView }
    return makeChromeView()
  }

  func install(in window: NSWindow, showsSpaceToolbar: Bool) {
    self.window = window
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    window.initialFirstResponder = browserView
    _ = view
    chromeView?.installTrafficLights(in: window)

    windowObservations.removeAll()
    for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                 NSWindow.didExitFullScreenNotification] {
      NotificationCenter.default.publisher(for: name, object: window)
        .sink { [weak self] _ in
          MainActor.assumeIsolated { self?.handle(.geometryChanged) }
        }
        .store(in: &windowObservations)
    }
    setSpaceControlsVisible(showsSpaceToolbar)
    bindSelectedSession(workspace.selectedSession)
    updateSidebarState()
  }

  func setSpaceControlsVisible(_ visible: Bool) {
    chromeView?.setAddressVisible(visible)
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
    guard let window, let chromeView,
          chromeView.window === window, browserView.window === window else { return }
    let browserRect = browserView.convert(browserView.bounds, to: chromeView)
    chromeView.applyLayout(browserRect: browserRect)
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

  private func makeChromeView() -> ToolbarChromeView {
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
    view.setAccessibilityRole(.toolbar)
    view.setAccessibilityLabel("Toolbar")
    chromeView = view
    return view
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
