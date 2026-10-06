//
//  BrowserToolbarController.swift
//  NativeBrowser
//
//  Stable tab-bound page toolbars with native page controls. Their
//  height comes from the same metric as the navigation rail; AppKit no longer
//  adds an independent toolbar safe area above the Main View.
//

import AppKit
import Combine
import SwiftUI
import Security
import SecurityInterface

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

/// Page-owned navigation and address views. The shell owns window controls;
/// Space owns its sidebar button. Both single-page and split layouts mount this
/// same tab-bound view, with no toolbar hand-off when the layout changes.
@MainActor
final class ToolbarChromeView: NSView {
  var onGeometryRequest: (() -> Void)?
  func refreshLayout() { onGeometryRequest?() }
  private let navigationGroup: NSHostingView<ToolbarNativeControlsView>
  private let backButton: NSButton
  private let forwardButton: NSButton
  private let addressView: AddressOverlayHostingView
  private let presentation: ToolbarPresentationState
  private let navigationMotion = GlassComponentLayoutMotion()
  private let addressMotion = GlassComponentLayoutMotion()

  struct LayoutSource {
    let navigation: GlassComponentLayoutMotion.Pose?
    let address: GlassComponentLayoutMotion.Pose?
  }

  func captureLayout() -> LayoutSource {
    LayoutSource(navigation: presentation.isVisible ? navigationMotion.capture(navigationGroup) : nil,
                 address: presentation.isVisible ? addressMotion.capture(addressView) : nil)
  }

  func animateLayout(from source: LayoutSource, enabled: Bool) {
    navigationGroup.layoutSubtreeIfNeeded()
    addressView.layoutSubtreeIfNeeded()
    navigationMotion.animate(navigationGroup, from: source.navigation, enabled: enabled)
    addressMotion.animate(addressView, from: source.address, enabled: enabled)
  }

  fileprivate init(backButton: NSButton, forwardButton: NSButton,
                   addressView: AddressOverlayHostingView,
                   presentation: ToolbarPresentationState) {
    self.backButton = backButton
    self.forwardButton = forwardButton
    self.addressView = addressView
    self.presentation = presentation
    let height = AddressCapsuleLayout.height
    let navigationContent = NSView(frame: NSRect(x: 0, y: 0,
                                                width: 2 + 2 * height, height: height))
    navigationContent.addSubview(backButton)
    navigationContent.addSubview(forwardButton)
    backButton.frame = NSRect(x: 1, y: 0, width: height, height: height)
    forwardButton.frame = NSRect(x: 1 + height, y: 0, width: height, height: height)
    // Custom shell chrome doesn't receive NSToolbar's automatic group glass.
    // Embed the native buttons as content over the system glass material,
    // adaptive symbol appearance and supported glass interaction feedback.
    // USER-REQUIRED STYLE CONTRACT: Back/Forward are independent native buttons
    // inside ONE continuous Liquid Glass capsule, matching the Safari reference.
    // Preserve the shared glass, native hover/press feedback (where supported),
    // independent enabled states, and geometry derived from the shared metrics.
    // Do not replace this with a plain segmented control, separate glass circles,
    // an inert background, or custom-drawn glass/interaction animations.
    // If platform limitations or another requirement conflict with this contract,
    // explain the conflict and obtain an explicit human trade-off decision before
    // changing the style or relaxing its native behavior or layout constraints.
    // SwiftUI supplies one native Liquid Glass surface and its public
    // materialize transition; the AppKit buttons remain mounted inside it.
    navigationGroup = NSHostingView(rootView: ToolbarNativeControlsView(
      content: navigationContent, presentation: presentation,
      size: NSSize(width: 2 + 2 * height, height: height)))
    super.init(frame: NSRect(x: 0, y: 0, width: 1, height: BrowserLayout.chromeThickness))
    navigationGroup.wantsLayer = true
    addressView.wantsLayer = true
    navigationGroup.safeAreaRegions = []
    navigationGroup.clipsToBounds = false
    navigationContent.autoresizingMask = [.width, .height]
    addSubview(navigationGroup)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard presentation.isVisible, let hit = super.hitTest(point),
          hit.isDescendant(of: navigationGroup) else { return nil }
    return hit
  }

  /// Lets the shell reserve native button/editor interactions before handling
  /// window dragging, without making it the owner of any page controls.
  func containsControl(at windowPoint: NSPoint) -> Bool {
    guard presentation.isVisible, let window else { return false }
    for button in [backButton, forwardButton] where button.window === window {
      if button.bounds.contains(button.convert(windowPoint, from: nil)) { return true }
    }
    if let host = addressView.superview,
       addressView.hitTest(host.convert(windowPoint, from: nil)) != nil { return true }
    return false
  }

  func setPageControlsVisible(_ visible: Bool, animated: Bool, animation: Animation? = nil) {
    presentation.setVisible(visible, animated: animated && window != nil, animation: animation)
  }

  func setNavigationState(canGoBack: Bool, canGoForward: Bool, hasSession: Bool) {
    backButton.isEnabled = hasSession && canGoBack
    forwardButton.isEnabled = hasSession && canGoForward
  }

  func applyLayout(browserRect: NSRect, preparingToShow: Bool = false) {
    guard browserRect.width > 0, presentation.isVisible || preparingToShow else { return }
    let height = AddressCapsuleLayout.height
    let y = (bounds.height - height) / 2
    let reservedEdge = (superview as? BrowserToolbarLayoutHosting).map {
      convert(NSPoint(x: $0.pageControlsLeadingEdge, y: 0), from: superview).x
    } ?? browserRect.minX
    let navigationLeft = max(browserRect.minX + BrowserLayout.pageControlInset,
                             reservedEdge + BrowserLayout.chromeControlSpacing)
    let addressWidth = browserRect.width * AddressCapsuleLayout.focusedWidthRatio
    let addressLeft = max(browserRect.midX - addressWidth / 2,
                          navigationLeft + 2 + 2 * height + BrowserLayout.pageControlInset)
    setFrame(NSRect(x: navigationLeft, y: y, width: 2 + 2 * height, height: height),
             on: navigationGroup)
    if let contentView = superview {
      if addressView.superview !== contentView {
        contentView.addSubview(addressView, positioned: .above, relativeTo: nil)
      }
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
    case sessionChanged
    case addressFocusChanged(BrowserSession, Bool)
    case addressFocusRequested(BrowserSession)
    case addressReloadOrStop(BrowserSession)
  }

  private let workspace: BrowserWorkspaceStore
  private let addressAutocomplete: AddressAutocompleteModel
  private let browserView: NSView
  /// Identity is fixed for the lifetime of this page, regardless of layout.
  let tabID: UUID
  var arePageControlsVisible: Bool { toolbarPresentation.isVisible }
  var onAddressCapsuleLayout: (() -> Void)?
  private let isActivePane: (() -> Bool)?
  private let onActivatePane: (() -> Void)?
  private var isDisposed = false
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

  /// One controller per page identity. Mount its view in the shell's overlay
  /// layer; bind browserView to that page's stable viewport, not a split-only guide.
  init(
    workspace: BrowserWorkspaceStore,
    history: HistoryService,
    browserView: NSView,
    tabID: UUID,
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
    workspace.session(for: tabID)
  }

  private func isActive(_ session: BrowserSession) -> Bool {
    boundSession === session && workspace.selectedSession === session
      && (isActivePane?() ?? true)
  }

  private func activatePane(for session: BrowserSession) {
    guard boundSession === session, !isActive(session) else { return }
    if let onActivatePane { onActivatePane() }
    else { workspace.selectTab(id: session.tabID) }
  }

  /// Mount as a sibling of the supplied browser view, above its page surface.
  var view: ToolbarChromeView {
    if let chromeView { return chromeView }
    return makeChromeView()
  }

  /// The address panel may include suggestions below its top capsule. Supply
  /// only the capsule's geometry so pane actions share its actual centre.
  func addressCapsuleFrame(in host: NSView?) -> CGRect? {
    guard let addressOverlay, addressOverlay.superview != nil,
          addressOverlay.bounds.width > 0 else { return nil }
    let y = addressOverlay.isFlipped ? addressOverlay.bounds.minY
      : addressOverlay.bounds.maxY - AddressCapsuleLayout.height
    return addressOverlay.convert(CGRect(x: addressOverlay.bounds.minX, y: y,
      width: addressOverlay.bounds.width, height: AddressCapsuleLayout.height), to: host)
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

  func install(in window: NSWindow) {
    guard !isDisposed else { return }
    self.window = window
    _ = view
    installSiteInformationEventMonitor()

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
    bindSession(boundSession)
  }

  /// Visibility is driven solely by whether the page is in the visible layout.
  func setPageControlsVisible(_ visible: Bool, animated: Bool = true, animation: Animation? = nil) {
    guard !isDisposed else { return }
    if visible { preparePageControlsForAppearance() }
    if !visible {
      siteInformation.dismiss()
      releaseAddressFocus()
    }
    chromeView?.setPageControlsVisible(visible, animated: animated, animation: animation)
    handle(.geometryChanged)
  }

  func captureLayout() -> ToolbarChromeView.LayoutSource { view.captureLayout() }

  func layoutChrome(frame: CGRect, from source: ToolbarChromeView.LayoutSource, animated: Bool) {
    if view.frame != frame { view.frame = frame }
    applyCurrentLayout(preparingToShow: true)
    view.animateLayout(from: source, enabled: animated)
  }

  func browserGeometryDidChange() {
    handle(.geometryChanged)
  }

  private func handle(_ event: ToolbarEvent) {
    guard !isDisposed else { return }
    switch event {
    case .sessionChanged:
      let session = boundSession
      let changed = observedSession !== session
      if changed || (session.map { !isActive($0) } ?? true) {
        siteInformation.dismiss()
        releaseAddressFocus()
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
      // Focus only this tab's stable editor, after its overlay is mounted.
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

  private func preparePageControlsForAppearance() {
    guard !toolbarPresentation.isVisible else { return }
    // Mount and lay out the hidden native hosts at the destination first. In
    // particular, a newly created address overlay must render its invisible,
    // enlarged state before the visibility transaction begins.
    applyCurrentLayout(preparingToShow: true)
    chromeView?.layoutSubtreeIfNeeded()
    addressOverlay?.layoutSubtreeIfNeeded()
  }

  private func applyCurrentLayout(preparingToShow: Bool = false) {
    guard let window, let chromeView,
          chromeView.window === window, browserView.window === window else { return }
    // The outer layout has already placed this chrome. Its geometry can differ
    // from a collapsed content crop when controls return after preview cancellation.
    let browserRect = chromeView.bounds
    chromeView.applyLayout(browserRect: browserRect,
                          preparingToShow: preparingToShow)
    onAddressCapsuleLayout?()
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
    action: Selector,
    usesSharedGlass: Bool = false
  ) -> NSButton {
    let size = BrowserLayout.chromeControlSize
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
    // Page navigation buttons receive glass from their shared native capsule.
    // Retain independent enabled states and system hover feedback.
    button.setButtonType(.momentaryPushIn)
    button.bezelStyle = usesSharedGlass ? .toolbar : .glass
    button.borderShape = .circle
    button.controlSize = .large
    button.isBordered = true
    button.showsBorderOnlyWhileMouseInside = usesSharedGlass
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
    let backButton = makeButton(
      label: "Back", symbol: "chevron.backward", action: #selector(goBack(_:)),
      usesSharedGlass: true)
    let forwardButton = makeButton(
      label: "Forward", symbol: "chevron.forward", action: #selector(goForward(_:)),
      usesSharedGlass: true)
    let addressView = AddressOverlayHostingView(rootView: ToolbarAddressFieldView(
      workspace: workspace,
      tabID: tabID,
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
      backButton: backButton,
      forwardButton: forwardButton,
      addressView: addressView,
      presentation: toolbarPresentation)
    view.setAccessibilityRole(.toolbar)
    view.setAccessibilityLabel("Page Toolbar")
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

  @objc private func goBack(_ sender: NSButton) {
    guard !isDisposed, toolbarPresentation.isVisible, sender.isEnabled,
          let session = boundSession else { return }
    siteInformation.dismiss()
    activatePane(for: session)
    session.goBack()
  }

  @objc private func goForward(_ sender: NSButton) {
    guard !isDisposed, toolbarPresentation.isVisible, sender.isEnabled,
          let session = boundSession else { return }
    siteInformation.dismiss()
    activatePane(for: session)
    session.goForward()
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
