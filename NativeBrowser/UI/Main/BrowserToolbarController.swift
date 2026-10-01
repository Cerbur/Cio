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
  private let sidebarButton: NSButton
  private let sidebarGlass: NSHostingView<ToolbarGlassControlView>
  private let navigationGroup: NSHostingView<ToolbarGlassControlView>
  private let backButton: NSButton
  private let forwardButton: NSButton
  private let addressView: AddressOverlayHostingView
  private let presentation: ToolbarPresentationState
  private var trafficLights: [NSButton] = []
  private weak var trafficLightsWindow: NSWindow?

  init(
    sidebarButton: NSButton,
    backButton: NSButton,
    forwardButton: NSButton,
    addressView: AddressOverlayHostingView,
    presentation: ToolbarPresentationState
  ) {
    self.sidebarButton = sidebarButton
    self.backButton = backButton
    self.forwardButton = forwardButton
    self.addressView = addressView
    self.presentation = presentation
    let height = AddressCapsuleLayout.height
    let navigationContent = NSView(frame: NSRect(x: 0, y: 0,
                                                width: 2 + 2 * height, height: height))
    sidebarGlass = NSHostingView(rootView: ToolbarGlassControlView(
      content: sidebarButton, presentation: presentation,
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

    addSubview(sidebarGlass)
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
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    if !presentation.isVisible, let hit,
       hit.isDescendant(of: sidebarGlass) || hit.isDescendant(of: navigationGroup) {
      return self
    }
    return hit
  }

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

  func setAddressVisible(_ visible: Bool, animated: Bool) {
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
  private let toolbarPresentation = ToolbarPresentationState()
  private let siteInformation = AddressSiteInformationState()
  private weak var addressOverlay: AddressOverlayHostingView?
  nonisolated(unsafe) private var siteInformationEventMonitor: Any?
  private var certificatePanel: SFCertificatePanel?
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

  deinit {
    if let siteInformationEventMonitor { NSEvent.removeMonitor(siteInformationEventMonitor) }
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
    NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.siteInformation.dismiss() }
      }
      .store(in: &windowObservations)
    setSpaceControlsVisible(showsSpaceToolbar, animated: false)
    bindSelectedSession(workspace.selectedSession)
    updateSidebarState()
  }

  func setSpaceControlsVisible(_ visible: Bool, animated: Bool = true) {
    if !visible { siteInformation.dismiss() }
    if !visible, addressPresentation.isFocused {
      addressAutocomplete.end()
      addressPresentation.isFocused = false
      window?.makeFirstResponder(nil)
      observedSession?.addressFieldFocusChanged(false)
    }
    chromeView?.setAddressVisible(visible, animated: animated)
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
      if observedSession !== workspace.selectedSession { siteInformation.dismiss() }
      if observedSession !== workspace.selectedSession, addressPresentation.isFocused {
        addressAutocomplete.end()
        addressPresentation.isFocused = false
        window?.makeFirstResponder(nil)
        observedSession?.addressFieldFocusChanged(false)
        workspace.selectedSession?.focusPage()
      }
      bindSelectedSession(workspace.selectedSession)
    case .addressFocusChanged(let session, let focused):
      guard workspace.selectedSession === session,
            !focused || toolbarPresentation.isVisible else { return }
      addressPresentation.isFocused = focused
      if focused { siteInformation.dismiss() }
      session.addressFieldFocusChanged(focused)
    case .addressFocusRequested(let session):
      guard workspace.selectedSession === session, toolbarPresentation.isVisible else { return }
      siteInformation.dismiss()
      NotificationCenter.default.post(
        name: .browserAddressFieldShouldFocus,
        object: session.addressField)
    case .addressReloadOrStop(let session):
      guard workspace.selectedSession === session else { return }
      siteInformation.dismiss()
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
    installSiteInformationEventMonitor()
    let view = ToolbarChromeView(
      sidebarButton: sidebarButton,
      backButton: backButton,
      forwardButton: forwardButton,
      addressView: addressView,
      presentation: toolbarPresentation)
    view.setAccessibilityRole(.toolbar)
    view.setAccessibilityLabel("Toolbar")
    chromeView = view
    return view
  }

  @objc private func handleSidebarToggle(_ sender: NSButton) {
    onSidebarToggle()
  }

  @objc private func goBack(_ sender: NSButton) {
    siteInformation.dismiss()
    workspace.selectedSession?.goBack()
  }

  @objc private func goForward(_ sender: NSButton) {
    siteInformation.dismiss()
    workspace.selectedSession?.goForward()
  }

  private func toggleSiteInformation(for session: BrowserSession) {
    guard workspace.selectedSession === session, toolbarPresentation.isVisible else { return }
    if siteInformation.isPresented { closeSiteInformation(); return }
    addressAutocomplete.end()
    addressPresentation.isFocused = false
    session.addressFieldFocusChanged(false)
    session.blur()
    siteInformation.present(session.siteInformation)
  }

  private func closeSiteInformation() {
    siteInformation.dismiss()
    workspace.selectedSession?.focusPage()
  }

  private func showCertificate(_ information: SiteInformation) {
    guard let window, let session = workspace.selectedSession,
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
    if !addressPresentation.isFocused { workspace.selectedSession?.focusPage() }
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
        if !self.addressPresentation.isFocused { self.workspace.selectedSession?.focusPage() }
      }
      return event
    }
  }

}
