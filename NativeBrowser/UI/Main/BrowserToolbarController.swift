//
//  BrowserToolbarController.swift
//  NativeBrowser
//
//  Shell and tab-bound pane toolbars with native page controls. Their
//  height comes from the same metric as the navigation rail; AppKit no longer
//  adds an independent toolbar safe area above the Main View.
//

import AppKit
import Combine
import SwiftUI
import Security
import SecurityInterface

/// Keep native button tracking and symbol rendering, but give the hover and
/// pressed backgrounds a circular outline instead of the toolbar bezel.
@MainActor
private final class CircularToolbarButtonCell: NSButtonCell {
  override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
    guard isEnabled else { return }
    let diameter = max(0, min(frame.width, frame.height) - 8)
    let circle = NSRect(x: frame.midX - diameter / 2, y: frame.midY - diameter / 2,
                        width: diameter, height: diameter)
    NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
    NSBezierPath(ovalIn: circle).fill()
  }
}

@MainActor
private final class AddressOverlayHostingView: NSHostingView<ToolbarAddressFieldView> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard rootView.presentation.isVisible else { return nil }
    let local = convert(point, from: superview)
    let focused = rootView.interaction.isFocused
    let rows = focused ? rootView.autocomplete.suggestions.count : 0
    let width = rootView.siteInformation.width(in: bounds.width, focused: focused)
    let height = rootView.siteInformation.height(rowCount: rows)
    let rect = NSRect(x: (bounds.width - width) / 2,
                      y: isFlipped ? 0 : bounds.height - height, width: width, height: height)
    guard rect.contains(local) else { return nil }
    return super.hitTest(point)
  }
}

@MainActor
private final class ToolbarChromeView: NSView {
  var onGeometryRequest: (() -> Void)?
  private let sidebarButton: NSButton
  private let sidebarGlass: NSHostingView<ToolbarGlassControlView>
  private let navigationGroup: NSHostingView<ToolbarGlassControlView>
  private let backButton: NSButton
  private let forwardButton: NSButton
  private let addressView: AddressOverlayHostingView
  private let presentation: ToolbarPresentationState
  private let showsWindowControls: Bool
  private let sidebarPresentation = ToolbarPresentationState()
  private var trafficLights: [NSButton] = []
  private weak var trafficLightsWindow: NSWindow?

  init(
    sidebarButton: NSButton,
    backButton: NSButton,
    forwardButton: NSButton,
    addressView: AddressOverlayHostingView,
    presentation: ToolbarPresentationState,
    showsWindowControls: Bool
  ) {
    self.sidebarButton = sidebarButton
    self.backButton = backButton
    self.forwardButton = forwardButton
    self.addressView = addressView
    self.presentation = presentation
    self.showsWindowControls = showsWindowControls
    let height = AddressCapsuleLayout.height
    let navigationContent = NSView(frame: NSRect(x: 0, y: 0,
                                                width: 2 + 2 * height, height: height))
    sidebarGlass = NSHostingView(rootView: ToolbarGlassControlView(
      content: sidebarButton, presentation: sidebarPresentation,
      size: NSSize(width: height, height: height)))
    navigationGroup = NSHostingView(rootView: ToolbarGlassControlView(
      content: navigationContent, presentation: presentation,
      size: NSSize(width: 2 + 2 * height, height: height)))
    super.init(frame: NSRect(x: 0, y: 0, width: 1, height: BrowserLayout.chromeThickness))

    for host in [sidebarGlass, navigationGroup] {
      host.safeAreaRegions = []
      host.clipsToBounds = false
    }
    sidebarButton.frame = NSRect(x: 0, y: 0, width: height, height: height)
    sidebarButton.autoresizingMask = [.width, .height]
    navigationContent.autoresizingMask = [.width, .height]

    if showsWindowControls { addSubview(sidebarGlass) }
    addSubview(navigationGroup)
    navigationContent.addSubview(backButton)
    navigationContent.addSubview(forwardButton)
    // The field is a shell overlay, keeping the same native editor mounted
    // while its glass expands over the Main View.

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
  override var mouseDownCanMoveWindow: Bool { showsWindowControls }

  override func mouseDown(with event: NSEvent) {
    if showsWindowControls { window?.performDrag(with: event) }
    else { super.mouseDown(with: event) }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    if !showsWindowControls {
      // Pane chrome overlaps the shell's toolbar row. Only its visible page
      // controls handle input; empty space must reach the shell's sidebar and
      // window controls (and retain the shell's window-drag behavior).
      guard presentation.isVisible, let hit,
            hit.isDescendant(of: navigationGroup) else { return nil }
      return hit
    }
    if let hit {
      if !sidebarPresentation.isVisible, hit.isDescendant(of: sidebarGlass) { return self }
      if !presentation.isVisible, hit.isDescendant(of: navigationGroup) { return self }
    }
    return hit
  }

  func installTrafficLights(in window: NSWindow) {
    guard showsWindowControls, trafficLightsWindow !== window else { return }
    trafficLights.forEach { $0.removeFromSuperview() }
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
    guard showsWindowControls else { return }
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

  func setAddressVisible(_ visible: Bool, animated: Bool) {
    sidebarPresentation.setVisible(visible, animated: animated && window != nil)
    setPageControlsVisible(visible, animated: animated)
  }

  func setPageControlsVisible(_ visible: Bool, animated: Bool) {
    presentation.setVisible(visible, animated: animated && window != nil)
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

  private func windowControlsTrailingEdge(in view: NSView) -> CGFloat? {
    guard showsWindowControls else { return nil }
    // Keep this reservation while library panels hide the shell controls.
    // Pane controls may restore before the sidebar button becomes visible;
    // their layout must not depend on the order of those visibility updates.
    // Refresh the shell first: sidebar-collapse notifications can reach pane
    // toolbars before the shell has laid out its window controls.
    onGeometryRequest?()
    return view.convert(sidebarGlass.bounds, from: sidebarGlass).maxX
  }

  func applyLayout(
    browserRect: NSRect, sidebarAnchor: NSRect
  ) {
    guard browserRect.width > 0 else { return }
    layoutTrafficLights()
    let trafficLightsRight = trafficLights.last?.frame.maxX ?? 0
    let height = AddressCapsuleLayout.height
    let y = (bounds.height - height) / 2
    let sidebarLeft = max(trafficLightsRight + 10, sidebarAnchor.minX - height - 10)
    let defaultNavigationLeft = showsWindowControls
      ? max(browserRect.minX + 7, sidebarLeft + height + 10) : browserRect.minX + 7
    // Pane and shell toolbars share the chrome host. Reserve the shell's actual
    // window-control area in this pane's coordinates, including during motion.
    let windowControlsRight = showsWindowControls ? nil : superview?.subviews
      .compactMap { $0 as? ToolbarChromeView }
      .first(where: { $0.showsWindowControls })?
      .windowControlsTrailingEdge(in: self)
    let navigationLeft = max(defaultNavigationLeft, windowControlsRight.map { $0 + 10 } ?? defaultNavigationLeft)
    // Keep the host at its maximum width. SwiftUI animates the capsule inside
    // it so the native glass is never clipped by the host's rectangular bounds.
    let addressWidth = browserRect.width * AddressCapsuleLayout.focusedWidthRatio
    let addressLeft = max(browserRect.midX - addressWidth / 2,
                          navigationLeft + 2 + 2 * height + 7)

    setFrame(NSRect(x: sidebarLeft, y: y, width: height, height: height),
             on: sidebarGlass)
    setFrame(NSRect(x: navigationLeft, y: y, width: 2 + 2 * height, height: height),
             on: navigationGroup)
    if let contentView = superview {
      if addressView.superview !== contentView { contentView.addSubview(addressView, positioned: .above, relativeTo: nil) }
      let anchor = convert(NSRect(x: addressLeft, y: y, width: addressWidth, height: height), to: contentView)
      let panelHeight = max(AddressCapsuleLayout.maximumHeight,
                            AddressCapsuleLayout.height + AddressSiteInformationState.contentHeight)
      let originY = contentView.isFlipped ? anchor.minY : anchor.maxY - panelHeight
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
  private var browserViewportFrame: CGRect?
  /// Nil follows selection (shell); a UUID binds every control to that tab.
  let tabID: UUID?
  var isPaneToolbar: Bool { tabID != nil }
  private let isActivePane: (() -> Bool)?
  private let onActivatePane: (() -> Void)?
  private var isDisposed = false
  private let isSidebarCollapsed: () -> Bool
  private let onSidebarToggle: () -> Void
  private weak var window: NSWindow?
  nonisolated(unsafe) private var chromeView: ToolbarChromeView?
  private var browserFrameObservation: AnyCancellable?
  private var windowObservations = Set<AnyCancellable>()
  private var workspaceObservation: AnyCancellable?
  private var selectedSessionObservations = Set<AnyCancellable>()
  private weak var observedSession: BrowserSession?
  private let addressPresentation = BrowserInteractionState()
  private let toolbarPresentation = ToolbarPresentationState()
  private let siteInformation = AddressSiteInformationState()
  nonisolated(unsafe) private var addressOverlay: AddressOverlayHostingView?
  nonisolated(unsafe) private var siteInformationEventMonitor: Any?
  private var certificatePanel: SFCertificatePanel?
  private var addressFocusRequestObservation: AnyCancellable?

  /// Omit `tabID` for the existing shell toolbar, including window/sidebar controls.
  /// Supply `tabID` and that pane's `browserView` for an independent pane toolbar.
  /// `isActivePane` optionally adds the host's active-pane check to selected-session
  /// command routing; `onActivatePane` selects the pane on address interaction
  /// (by default this calls `workspace.selectTab(id:)`). Mount `view`, then call
  /// `install(in:showsSpaceToolbar:)`; call `removeFromPresentation()` when hidden
  /// (it can be mounted and installed again), or `dispose()` to end its lifetime.
  init(
    workspace: BrowserWorkspaceStore,
    history: HistoryService,
    browserView: NSView,
    isSidebarCollapsed: @escaping () -> Bool = { true },
    onSidebarToggle: @escaping () -> Void = {},
    tabID: UUID? = nil,
    initiallyVisible: Bool = true,
    isActivePane: (() -> Bool)? = nil,
    onActivatePane: (() -> Void)? = nil
  ) {
    self.workspace = workspace
    self.addressAutocomplete = AddressAutocompleteModel(history: history)
    self.browserView = browserView
    self.tabID = tabID
    self.isActivePane = isActivePane
    self.onActivatePane = onActivatePane
    self.isSidebarCollapsed = isSidebarCollapsed
    self.onSidebarToggle = onSidebarToggle
    super.init()
    toolbarPresentation.setVisible(initiallyVisible, animated: false)
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
    bindSession(boundSession)
  }

  private var boundSession: BrowserSession? {
    if let tabID { return workspace.session(for: tabID) }
    return workspace.selectedSession
  }

  private func isActive(_ session: BrowserSession) -> Bool {
    boundSession === session && workspace.selectedSession === session
      && (isActivePane?() ?? true)
  }

  private func activatePane(for session: BrowserSession) {
    guard tabID != nil, boundSession === session, !isActive(session) else { return }
    if let onActivatePane { onActivatePane() }
    else { workspace.selectTab(id: session.tabID) }
  }

  /// Mount as a sibling of the supplied browser view, above its page surface.
  var view: NSView {
    if let chromeView { return chromeView }
    return makeChromeView()
  }

  deinit {
    if let siteInformationEventMonitor { NSEvent.removeMonitor(siteInformationEventMonitor) }
    // A window retains overlays independently of the toolbar's chrome. Capture
    // the view, never self, and remove it on AppKit's thread even on implicit disposal.
    DispatchQueue.main.async { [overlay = addressOverlay, chrome = chromeView] in
      overlay?.removeFromSuperview()
      chrome?.removeFromSuperview()
    }
  }

  /// Removes the window overlay, chrome, field editor and local event monitors.
  /// The host may later mount `view` and call `install` again on this controller.
  func removeFromPresentation() {
    releaseAddressFocus()
    siteInformation.dismiss()
    addressAutocomplete.end()
    windowObservations.removeAll()
    if let siteInformationEventMonitor {
      NSEvent.removeMonitor(siteInformationEventMonitor)
      self.siteInformationEventMonitor = nil
    }
    if let panel = certificatePanel {
      window?.endSheet(panel)
      panel.orderOut(nil)
      certificatePanel = nil
    }
    toolbarPresentation.setVisible(false, animated: false)
    addressOverlay?.removeFromSuperview()
    addressOverlay = nil
    chromeView?.removeFromSuperview()
    chromeView = nil
    window = nil
  }

  /// Idempotent final cleanup; a disposed controller must not be installed again.
  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    removeFromPresentation()
    browserFrameObservation = nil
    workspaceObservation = nil
    addressFocusRequestObservation = nil
    selectedSessionObservations.removeAll()
    observedSession = nil
  }

  private func releaseAddressFocus() {
    guard addressPresentation.isFocused else { return }
    addressPresentation.isFocused = false
    addressAutocomplete.end()
    // The window's field editor may already belong to another pane.
    if let overlay = addressOverlay, let window {
      func containsResponder(in view: NSView) -> Bool {
        if window.firstResponder === view { return true }
        if let field = view as? NSTextField, let editor = field.currentEditor(),
           window.firstResponder === editor { return true }
        return view.subviews.contains { containsResponder(in: $0) }
      }
      if containsResponder(in: overlay) { window.makeFirstResponder(nil) }
    }
    observedSession?.addressFieldFocusChanged(false)
  }

  func install(in window: NSWindow, showsSpaceToolbar: Bool) {
    guard !isDisposed else { return }
    self.window = window
    if tabID == nil {
      window.styleMask.insert(.fullSizeContentView)
      window.isOpaque = false
      window.backgroundColor = .clear
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.toolbar = nil
      window.initialFirstResponder = browserView
    }
    _ = view
    installSiteInformationEventMonitor()
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
    NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.siteInformation.dismiss() }
      }
      .store(in: &windowObservations)
    setSpaceControlsVisible(showsSpaceToolbar, animated: false)
    bindSession(boundSession)
    updateSidebarState()
  }

  func setSpaceControlsVisible(_ visible: Bool, animated: Bool = true) {
    guard !isDisposed else { return }
    if !visible { siteInformation.dismiss() }
    if !visible, addressPresentation.isFocused {
      releaseAddressFocus()
    }
    chromeView?.setAddressVisible(visible, animated: animated)
    handle(.geometryChanged)
  }

  /// Shows/hides only navigation and address controls. The shell keeps its
  /// traffic lights and sidebar button while split panes provide page controls.
  func setPageControlsVisible(_ visible: Bool, animated: Bool = true) {
    guard !isDisposed else { return }
    if !visible {
      siteInformation.dismiss()
      releaseAddressFocus()
    }
    chromeView?.setPageControlsVisible(visible, animated: animated)
    handle(.geometryChanged)
  }

  func updateSidebarState() {
    handle(.sidebarChanged)
  }

  /// Match the tab-placement crop while the browser's real frame stays unchanged.
  func setBrowserViewportFrame(_ frame: CGRect?) {
    guard browserViewportFrame != frame else { return }
    browserViewportFrame = frame
    handle(.geometryChanged)
  }

  func browserGeometryDidChange() {
    handle(.geometryChanged)
  }

  private func handle(_ event: ToolbarEvent) {
    guard !isDisposed else { return }
    switch event {
    case .sidebarChanged:
      chromeView?.setSidebarCollapsed(isSidebarCollapsed())
    case .sessionChanged:
      let session = boundSession
      let changed = observedSession !== session
      let hadAddressFocus = addressPresentation.isFocused
      if changed || (session.map { !isActive($0) } ?? true) {
        siteInformation.dismiss()
        releaseAddressFocus()
        if changed, hadAddressFocus, !isPaneToolbar { session?.focusPage() }
      }
      bindSession(session)
    case .addressFocusChanged(let session, let focused):
      guard boundSession === session,
            !focused || toolbarPresentation.isVisible else { return }
      if focused { activatePane(for: session) }
      addressPresentation.isFocused = focused
      if focused { siteInformation.dismiss() }
      session.addressFieldFocusChanged(focused)
    case .addressFocusRequested(let session):
      guard isActive(session), toolbarPresentation.isVisible,
            let window, chromeView?.window === window else { return }
      siteInformation.dismiss()
      // Focus only this overlay's editor. Broadcasting its model would also
      // reach the hidden shell editor bound to the same selected session.
      DispatchQueue.main.async { [weak self, weak session] in
        guard let self, let session, self.isActive(session),
              self.toolbarPresentation.isVisible, let overlay = self.addressOverlay,
              overlay.window === self.window else { return }
        self.addressField(in: overlay)?.focusAndSelectAll()
      }
    case .addressReloadOrStop(let session):
      guard boundSession === session, toolbarPresentation.isVisible else { return }
      siteInformation.dismiss()
      activatePane(for: session)
      session.reloadOrStop()
    case .geometryChanged:
      break
    }
    applyCurrentLayout()
  }

  private func addressField(in view: NSView) -> NativeBrowserAddressField? {
    if let field = view as? NativeBrowserAddressField { return field }
    for subview in view.subviews {
      if let field = addressField(in: subview) { return field }
    }
    return nil
  }

  private func applyCurrentLayout() {
    guard let window, let chromeView,
          chromeView.window === window, browserView.window === window else { return }
    let browserRect = browserView.convert(browserViewportFrame ?? browserView.bounds, to: chromeView)
    let sidebarAnchor = browserView.convert(browserView.bounds, to: chromeView)
    chromeView.applyLayout(browserRect: browserRect, sidebarAnchor: sidebarAnchor)
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

  private func bindSession(_ session: BrowserSession?) {
    // Explicitly update the mounted address view when selection changes. A
    // hidden shell toolbar must not retain the pane that just closed.
    let addressTabID = tabID ?? session?.tabID
    if let overlay = addressOverlay, overlay.rootView.tabID != addressTabID {
      overlay.rootView.tabID = addressTabID
    }
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

      session.$url.removeDuplicates().dropFirst()
        .sink { [weak self] _ in self?.siteInformation.dismiss() }
        .store(in: &selectedSessionObservations)
      session.$isLoading.removeDuplicates().dropFirst()
        .sink { [weak self, weak session] loading in
          guard let self, let session else { return }
          if loading { self.siteInformation.dismiss() }
          else {
            // @Published fires before the new value has reached the session.
            DispatchQueue.main.async { [weak self, weak session] in
              guard let self, let session, self.observedSession === session else { return }
              self.siteInformation.refresh(session.siteInformation)
            }
          }
        }
        .store(in: &selectedSessionObservations)
      Publishers.CombineLatest(session.$lastErrorCode, session.$rendererCrashed)
        .sink { [weak self] error, crashed in
          if error != nil || crashed { self?.siteInformation.dismiss() }
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
    button.cell = CircularToolbarButtonCell(textCell: "")
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
      tabID: tabID ?? boundSession?.tabID,
      interaction: addressPresentation,
      autocomplete: addressAutocomplete,
      presentation: toolbarPresentation,
      siteInformation: siteInformation,
      onFocusChange: { [weak self] session, focused in
        self?.handle(.addressFocusChanged(session, focused))
      },
      onReloadOrStop: { [weak self] session in
        self?.handle(.addressReloadOrStop(session))
      },
      onSiteInformationToggle: { [weak self] session in
        self?.toggleSiteInformation(for: session)
      },
      onCertificate: { [weak self] information in
        self?.showCertificate(information)
      }))
    addressView.safeAreaRegions = []
    addressView.clipsToBounds = false
    addressOverlay = addressView
    let view = ToolbarChromeView(
      sidebarButton: sidebarButton,
      backButton: backButton,
      forwardButton: forwardButton,
      addressView: addressView,
      presentation: toolbarPresentation,
      showsWindowControls: !isPaneToolbar)
    view.setAccessibilityRole(.toolbar)
    view.setAccessibilityLabel(tabID == nil ? "Toolbar" : "Pane Toolbar")
    chromeView = view
    view.onGeometryRequest = { [weak self] in self?.applyCurrentLayout() }
    if let session = boundSession {
      applyNavigationToolbarState(canGoBack: session.canGoBack,
                                  canGoForward: session.canGoForward, hasSession: true)
    } else {
      applyNavigationToolbarState(canGoBack: false, canGoForward: false, hasSession: false)
    }
    return view
  }

  @objc private func handleSidebarToggle(_ sender: NSButton) {
    guard !isDisposed, tabID == nil else { return }
    onSidebarToggle()
  }

  @objc private func goBack(_ sender: NSButton) {
    guard !isDisposed, toolbarPresentation.isVisible else { return }
    siteInformation.dismiss()
    if let session = boundSession {
      activatePane(for: session)
      session.goBack()
    }
  }

  @objc private func goForward(_ sender: NSButton) {
    guard !isDisposed, toolbarPresentation.isVisible else { return }
    siteInformation.dismiss()
    if let session = boundSession {
      activatePane(for: session)
      session.goForward()
    }
  }

  private func toggleSiteInformation(for session: BrowserSession) {
    guard !isDisposed, boundSession === session, toolbarPresentation.isVisible else { return }
    activatePane(for: session)
    if siteInformation.isPresented { closeSiteInformation(); return }
    addressAutocomplete.end()
    addressPresentation.isFocused = false
    session.addressFieldFocusChanged(false)
    session.blur()
    siteInformation.present(session.siteInformation)
  }

  private func focusBoundPageIfActive() {
    guard !isDisposed, let session = boundSession, isActive(session) else { return }
    session.focusPage()
  }

  private func closeSiteInformation() {
    siteInformation.dismiss()
    focusBoundPageIfActive()
  }

  private func showCertificate(_ information: SiteInformation) {
    guard let window, let session = boundSession,
          session.url == information.url, !session.isLoading, !session.rendererCrashed,
          window.attachedSheet == nil else { return }
    let certificates = information.certificateChain.compactMap {
      SecCertificateCreateWithData(nil, $0 as CFData)
    }
    guard !certificates.isEmpty else { return }
    // The panel displays the exact chain used by Chromium. Its own trust
    // evaluation is omitted because macOS and Chromium can use different roots.
    siteInformation.dismiss()
    let panel = SFCertificatePanel()
    certificatePanel = panel
    panel.title = "网站证书 — \(information.host)"
    panel.beginSheet(for: window, modalDelegate: self,
                     didEnd: #selector(certificatePanelDidEnd(_:returnCode:contextInfo:)),
                     contextInfo: nil, certificates: certificates, showGroup: true)
  }

  @objc private func certificatePanelDidEnd(_ panel: NSWindow, returnCode: Int,
                                            contextInfo: UnsafeMutableRawPointer?) {
    certificatePanel = nil
    if !addressPresentation.isFocused { focusBoundPageIfActive() }
  }

  private func installSiteInformationEventMonitor() {
    guard siteInformationEventMonitor == nil else { return }
    siteInformationEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    ) { [weak self] event in
      guard let self, self.siteInformation.isPresented else { return event }
      if event.type == .keyDown {
        if event.keyCode == 53 { self.closeSiteInformation(); return nil }
        // Allow keyboard navigation and app shortcuts; dismiss before a
        // shortcut can focus the address editor or navigate to another page.
        if event.modifierFlags.contains(.command) { self.siteInformation.dismiss() }
        return event
      }
      guard event.window === self.window, let overlay = self.addressOverlay else {
        self.siteInformation.dismiss()
        return event
      }
      let point = overlay.convert(event.locationInWindow, from: nil)
      let width = self.siteInformation.width(in: overlay.bounds.width, focused: false)
      let height = self.siteInformation.height(rowCount: 0)
      let rect = NSRect(x: (overlay.bounds.width - width) / 2,
                        y: overlay.isFlipped ? 0 : overlay.bounds.height - height,
                        width: width, height: height)
      if !rect.contains(point) {
        self.siteInformation.dismiss()
        // Hand focus back for the same click to reach the Chromium page.
        if !self.addressPresentation.isFocused { self.focusBoundPageIfActive() }
      }
      return event
    }
  }

}
