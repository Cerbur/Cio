//
//  BrowserSurfaceHostView.swift
//  NativeBrowser
//
//  The stable AppKit host for every live Chromium surface in the window
//  (Milestone 3 section 11).
//
//  Why this type exists: the obvious SwiftUI implementation of tab selection --
//
//      if tab.id == selectedTabID { ChromiumView(session: session) }
//
//  removes the inactive representable's NSView from the hierarchy, which
//  deallocates the CEF host view, which destroys the CefBrowser. Switching back
//  then builds a second browser for the same tab, and every switch loses the
//  tab's page state.
//
//  Instead, each live BrowserSession owns exactly one ChromiumContainerView that
//  stays a subview of this host for as long as the session is alive. Selection
//  only changes which container is visible; no browser is created, destroyed or
//  reparented by a tab switch.
//
//  The host creates and destroys nothing: the session manager owns the
//  containers and hands the current set in, so "remove a container" can only
//  happen after OnBeforeClose released its session.
//

import AppKit

final class BrowserSurfaceHostView: NSView {
  var onDarkAppearanceChange: ((Bool) -> Void)?
  var onSelectedSurfaceFrameChange: ((CGRect?) -> Void)?

  func syncChromiumAppearance() {
    guard window != nil else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    CEFProcessHost.setDarkAppearance(dark)
    onDarkAppearanceChange?(dark)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncChromiumAppearance()
    if let window {
      for toolbar in toolbars.values { toolbar.install(in: window, showsSpaceToolbar: !isCovered) }
      needsLayout = true
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncChromiumAppearance()
  }

  private var containers: [UUID: ChromiumContainerView] = [:]
  private var selectedTabID: UUID?
  private var split: BrowserSplitLayout?
  private var isCovered = false
  private var previewSide: BrowserSplitLayout.Side?
  private var isCommittingSplitPreview = false
  private var resizingFraction: CGFloat?
  private var toolbarFrames: [UUID: CGRect] = [:]
  private var selectedToolbarFrame: CGRect?
  private var toolbarTargetFrames: [UUID: CGRect] = [:]
  private var selectedToolbarTargetFrame: CGRect?
  private struct SurfacePlacement: Equatable {
    var frame: CGRect
    var cropOnly: Bool
    var roundedEdge: BrowserSplitLayout.Side?
  }
  private var surfacePlacements: [UUID: SurfacePlacement] = [:]
  private var surfaceTargets: [UUID: SurfacePlacement] = [:]
  nonisolated(unsafe) private var presentationAnimationTimer: Timer?
  private weak var workspace: BrowserWorkspaceStore?
  private var history: HistoryService?
  private var toolbars: [UUID: BrowserToolbarController] = [:]
  private var toolbarGuides: [UUID: NSView] = [:]
  private var unsplitButtons: [UUID: NSButton] = [:]
  private let divider = BrowserSplitDividerView()
  private let preview = NSVisualEffectView()
  nonisolated(unsafe) private var paneClickMonitor: Any?

  private var chromeOverlayHost: NSView? {
    var ancestor = superview
    while let candidate = ancestor {
      if candidate.identifier?.rawValue == "browser-shell-chrome-host" { return candidate }
      ancestor = candidate.superview
    }
    return nil
  }

  override var isFlipped: Bool { true }

  func configure(workspace: BrowserWorkspaceStore, history: HistoryService) {
    self.workspace = workspace
    self.history = history
    if paneClickMonitor == nil {
      paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        guard let self, event.window === self.window, let split = self.split,
              !self.isCovered, self.workspace?.isSpotlightPresented != true, self.preview.isHidden else { return event }
        let point = self.convert(event.locationInWindow, from: nil)
        guard self.bounds.contains(point), !self.divider.frame.contains(point) else { return event }
        let tabID = point.x < self.divider.frame.minX ? split.leftTabID : split.rightTabID
        self.workspace?.selectTab(id: tabID)
        return event
      }
    }
  }

  func setPresentationCovered(_ covered: Bool) {
    guard isCovered != covered else { return }
    isCovered = covered
    for id in toolbars.keys {
      layoutToolbar(for: id, in: toolbarFrames[id] ?? bounds, visible: toolbarFrames[id] != nil)
    }
  }

  func present(containers: [UUID: ChromiumContainerView], selectedTabID: UUID?, split: BrowserSplitLayout? = nil) {
    self.containers = containers
    self.selectedTabID = selectedTabID
    let pairChanged = self.split?.tabIDs != split?.tabIDs
    if self.split != nil, split == nil, let selectedTabID,
       let frame = toolbarFrames[selectedTabID] {
      selectedToolbarFrame = frame
    }
    self.split = split
    for (tabID, container) in containers {
      if container.superview !== self { addSubview(container, positioned: .below, relativeTo: divider) }
      container.autoresizingMask = []
      container.setSurfaceVisible(split?.contains(tabID) ?? (tabID == selectedTabID))
    }
    for case let container as ChromiumContainerView in subviews {
      if !containers.values.contains(where: { $0 === container }) { container.removeFromSuperview() }
    }
    if pairChanged { rebuildToolbars() }
    applySurfaceLayout(animatedPresentation: isCommittingSplitPreview || pairChanged)
  }

  override func layout() {
    super.layout()
    applySurfaceLayout()
  }

  /// Preview changes origins and layer masks only. No Chromium view changes size.
  func previewSplit(on side: BrowserSplitLayout.Side?) {
    guard previewSide != side else { return }
    previewSide = side
    applySurfaceLayout(animatedPresentation: true)
  }

  /// Consume the preview without first presenting the full-width page. The
  /// workspace publishes the committed pair synchronously inside this closure.
  func commitSplitPreview(_ commit: () -> Bool) -> Bool {
    let hadPreview = previewSide != nil
    if hadPreview, split == nil, let selectedTabID {
      // Transfer the shell's current animated frame to the surviving pane's
      // toolbar, including a drop before the preview animation has finished.
      toolbarFrames[selectedTabID] = selectedToolbarFrame ?? bounds
    }
    previewSide = nil
    isCommittingSplitPreview = hadPreview
    defer { isCommittingSplitPreview = false }
    let committed = commit()
    if !committed { applySurfaceLayout(animatedPresentation: hadPreview) }
    return committed
  }

  private func applySurfaceLayout(animatedPresentation: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    preview.isHidden = previewSide == nil
    var surfaces: [UUID: SurfacePlacement] = [:]
    if let side = previewSide, let split {
      let frames = split.frames(in: bounds)
      let survivorID = side == .left ? split.rightTabID : split.leftTabID
      let survivorFrame = side == .left ? frames.right : frames.left
      preview.frame = side == .left ? frames.left : frames.right
      divider.frame = frames.divider
      divider.isHidden = false
      for (id, container) in containers where container.isSurfaceVisible {
        surfaces[id] = SurfacePlacement(frame: id == survivorID ? survivorFrame : collapsedSurfaceFrame(for: id, container: container),
          cropOnly: true, roundedEdge: side)
      }
      updatePresentationLayout(panes: [survivorID: survivorFrame], selectedFrame: nil,
                               surfaces: surfaces, animated: animatedPresentation)
    } else if let side = previewSide {
      let currentWidth = selectedTabID.flatMap { containers[$0]?.frame.width } ?? bounds.width
      let frames = BrowserSplitLayout.previewFrames(in: bounds, on: side,
                                                   maximumSurvivorWidth: currentWidth)
      preview.frame = frames.target
      divider.isHidden = true
      for (id, container) in containers where container.isSurfaceVisible {
        // Keep every Chromium surface at its committed size during tab placement.
        surfaces[id] = SurfacePlacement(frame: id == selectedTabID ? frames.survivor : collapsedSurfaceFrame(for: id, container: container),
                                        cropOnly: true, roundedEdge: side)
      }
      let paneFrames = toolbars.keys.filter { $0 == selectedTabID }
        .reduce(into: [UUID: CGRect]()) { $0[$1] = frames.survivor }
      updatePresentationLayout(panes: paneFrames, selectedFrame: frames.survivor,
                               surfaces: surfaces, animated: animatedPresentation)
    } else if let split {
      var shown = split
      shown.fraction = resizingFraction ?? split.fraction
      let frames = shown.frames(in: bounds)
      for (id, frame) in [(split.leftTabID, frames.left), (split.rightTabID, frames.right)] {
        guard containers[id] != nil else { continue }
        // Divider drags resize Chromium immediately so responsive page layout
        // previews at the actual pane width, rather than cropping the old page.
        surfaces[id] = SurfacePlacement(frame: frame, cropOnly: false,
                                        roundedEdge: id == split.leftTabID ? .right : .left)
      }
      divider.frame = frames.divider
      divider.isHidden = false
      updatePresentationLayout(panes: [split.leftTabID: frames.left, split.rightTabID: frames.right],
                               selectedFrame: nil, surfaces: surfaces, animated: animatedPresentation)
    } else {
      divider.isHidden = true
      if let selectedTabID, containers[selectedTabID] != nil {
        surfaces[selectedTabID] = SurfacePlacement(frame: bounds, cropOnly: false, roundedEdge: nil)
      }
      updatePresentationLayout(panes: [:], selectedFrame: nil, surfaces: surfaces, animated: animatedPresentation)
    }
    // Inactive containers keep their last committed geometry and their live page.
  }

  /// Page origins and crop masks follow the same clock as their toolbar. Resize
  /// the surviving Chromium surface once the drop settles; splitter tracking
  /// still updates actual page widths immediately.
  private func updatePresentationLayout(panes: [UUID: CGRect], selectedFrame: CGRect?,
                                       surfaces: [UUID: SurfacePlacement], animated: Bool) {
    guard panes != toolbarTargetFrames || selectedFrame != selectedToolbarTargetFrame
      || surfaces != surfaceTargets else {
      // Layout may be repeated while a window or overlay is being attached.
      // Preserve an active transition; otherwise refresh the mounted controls.
      if presentationAnimationTimer == nil {
        applySurfacePlacements(surfaces)
        applyToolbarLayout(panes: panes, selectedFrame: selectedFrame)
      }
      return
    }
    toolbarTargetFrames = panes
    selectedToolbarTargetFrame = selectedFrame
    surfaceTargets = surfaces
    presentationAnimationTimer?.invalidate()
    presentationAnimationTimer = nil
    guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      applySurfacePlacements(surfaces)
      applyToolbarLayout(panes: panes, selectedFrame: selectedFrame)
      return
    }
    let startFrames = toolbarFrames
    let startSurfaces = surfacePlacements
    let startSelected = selectedToolbarFrame ?? bounds
    let endSelected = selectedFrame ?? bounds
    // Newly mounted pane controls must start at the transferred preview frame
    // immediately, rather than drawing their default frame until the first tick.
    let initialFrames = panes.map { id, end in (id, startFrames[id] ?? end) }
    // New panes adopt their committed size immediately. Existing panes retain
    // their live viewport while their visible crop moves toward its destination.
    applySurfacePlacements(interpolatedSurfaces(from: startSurfaces, to: surfaces, amount: 0))
    applyToolbarLayout(panes: Dictionary(uniqueKeysWithValues: initialFrames), selectedFrame: startSelected,
                       animatedVisibility: true)
    let startTime = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let progress = min(1, (ProcessInfo.processInfo.systemUptime - startTime) / 0.3)
        // Smooth acceleration/deceleration matches the glass block's morph.
        let amount = CGFloat(progress * progress * (3 - 2 * progress))
        let current = panes.map { id, end in
          (id, Self.interpolatedFrame(from: startFrames[id] ?? end, to: end, amount: amount))
        }
        self.applySurfacePlacements(self.interpolatedSurfaces(from: startSurfaces, to: surfaces, amount: amount))
        self.applyToolbarLayout(panes: Dictionary(uniqueKeysWithValues: current),
          selectedFrame: progress == 1 ? selectedFrame : Self.interpolatedFrame(
            from: startSelected, to: endSelected, amount: amount))
        if progress == 1 {
          self.presentationAnimationTimer?.invalidate()
          self.presentationAnimationTimer = nil
        }
      }
    }
    presentationAnimationTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func collapsedSurfaceFrame(for id: UUID, container: ChromiumContainerView) -> CGRect {
    // Collapse within the visible Chromium pane, including an interrupted preview.
    let frame = surfacePlacements[id]?.frame ?? container.frame
    return CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0)
  }

  private func interpolatedSurfaces(from start: [UUID: SurfacePlacement],
                                    to end: [UUID: SurfacePlacement], amount: CGFloat) -> [UUID: SurfacePlacement] {
    end.reduce(into: [:]) { result, entry in
      let (id, target) = entry
      guard amount < 1, let initial = start[id], initial.frame != target.frame else {
        result[id] = target
        return
      }
      result[id] = SurfacePlacement(frame: Self.interpolatedFrame(from: initial.frame, to: target.frame, amount: amount),
                                    cropOnly: true, roundedEdge: target.roundedEdge)
    }
  }

  private func applySurfacePlacements(_ placements: [UUID: SurfacePlacement]) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    surfacePlacements = placements
    for (id, placement) in placements {
      guard let container = containers[id] else { continue }
      place(container, in: placement.frame, cropOnly: placement.cropOnly, roundedEdge: placement.roundedEdge)
    }
  }

  private func applyToolbarLayout(panes: [UUID: CGRect], selectedFrame: CGRect?, animatedVisibility: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for id in toolbars.keys {
      layoutToolbar(for: id, in: panes[id] ?? toolbarFrames[id] ?? bounds,
                    visible: panes[id] != nil, animatedVisibility: animatedVisibility)
    }
    toolbarFrames = panes
    selectedToolbarFrame = selectedFrame
    onSelectedSurfaceFrameChange?(selectedFrame)
  }

  private static func interpolatedFrame(from start: CGRect, to end: CGRect, amount: CGFloat) -> CGRect {
    CGRect(x: start.minX + (end.minX - start.minX) * amount,
           y: start.minY + (end.minY - start.minY) * amount,
           width: start.width + (end.width - start.width) * amount,
           height: start.height + (end.height - start.height) * amount)
  }

  private func layoutToolbar(for id: UUID, in frame: CGRect, visible: Bool, animatedVisibility: Bool = false) {
    guard let toolbar = toolbars[id] else { return }
    toolbar.setSpaceControlsVisible(visible && !isCovered, animated: animatedVisibility)
    if let button = unsplitButtons[id] {
      setUnsplitButtonVisible(button, visible && !isCovered, animated: animatedVisibility)
    }
    if toolbarGuides[id]?.frame != frame { toolbarGuides[id]?.frame = frame }
    guard visible, let contentView = chromeOverlayHost else { return }
    if toolbar.view.superview !== contentView {
      contentView.addSubview(toolbar.view, positioned: .above, relativeTo: nil)
    }
    // Pane chrome occupies the shell's existing toolbar row.
    let toolbarFrame = convert(CGRect(x: frame.minX, y: -BrowserLayout.chromeThickness,
                                      width: frame.width, height: BrowserLayout.chromeThickness), to: contentView)
    if toolbar.view.frame != toolbarFrame { toolbar.view.frame = toolbarFrame }
    if let button = unsplitButtons[id] {
      if button.superview !== contentView { contentView.addSubview(button, positioned: .above, relativeTo: nil) }
      button.frame = convert(CGRect(x: frame.maxX - 30, y: -40, width: 24, height: 24), to: contentView)
    }
    toolbar.browserGeometryDidChange()
  }

  private func place(_ container: ChromiumContainerView, in frame: CGRect, cropOnly: Bool,
                     roundedEdge: BrowserSplitLayout.Side? = nil) {
    if cropOnly {
      container.setFrameOrigin(frame.origin)
    } else {
      if container.frame != frame { container.frame = frame }
    }
    guard cropOnly || roundedEdge != nil else {
      container.layer?.mask = nil
      return
    }
    // Round only the edge facing the other pane. The shared Main View retains
    // ownership of its outer corners, and preview masks do not resize Chromium.
    let mask = container.layer?.mask ?? CALayer()
    mask.backgroundColor = NSColor.black.cgColor
    // The host is flipped, while Chromium's container uses bottom-up coordinates.
    // Convert the visible rect so shrinking height keeps the mask at the pane's top.
    mask.frame = container.convert(frame, from: self)
    mask.cornerRadius = roundedEdge == nil ? 0 : BrowserLayout.contentCornerRadius
    mask.cornerCurve = .continuous
    mask.maskedCorners = roundedEdge == .right
      ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
      : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    container.layer?.mask = mask
  }

  private func setUnsplitButtonVisible(_ button: NSButton, _ visible: Bool, animated: Bool) {
    guard button.isEnabled != visible else { return }
    button.isEnabled = visible
    guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      button.alphaValue = visible ? 1 : 0
      button.isHidden = !visible
      return
    }
    if visible { button.isHidden = false }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      button.animator().alphaValue = visible ? 1 : 0
    } completionHandler: { [weak button] in
      MainActor.assumeIsolated {
        if let button, !button.isEnabled { button.isHidden = true }
      }
    }
  }

  private func rebuildToolbars() {
    let desiredIDs = Set(split?.tabIDs ?? [])
    let animates = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for id in Array(toolbars.keys) where !desiredIDs.contains(id) {
      guard let toolbar = toolbars.removeValue(forKey: id) else { continue }
      let guide = toolbarGuides.removeValue(forKey: id)
      let button = unsplitButtons.removeValue(forKey: id)
      toolbar.setSpaceControlsVisible(false, animated: animates)
      if let button { setUnsplitButtonVisible(button, false, animated: animates) }
      // Keep the glass and address overlay mounted until their exit finishes.
      if animates {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          toolbar.dispose()
          guide?.removeFromSuperview()
          button?.removeFromSuperview()
        }
      } else {
        toolbar.dispose()
        guide?.removeFromSuperview()
        button?.removeFromSuperview()
      }
    }
    guard let split, let workspace, let history else { return }
    for id in split.tabIDs where toolbars[id] == nil {
      let guide = NSView()
      guide.isHidden = true
      addSubview(guide)
      toolbarGuides[id] = guide
      let toolbar = BrowserToolbarController(workspace: workspace, history: history, browserView: guide,
        isSidebarCollapsed: { true }, onSidebarToggle: {}, tabID: id, initiallyVisible: false)
      if let contentView = chromeOverlayHost { contentView.addSubview(toolbar.view, positioned: .above, relativeTo: nil) }
      toolbars[id] = toolbar
      if let window { toolbar.install(in: window, showsSpaceToolbar: false) }
      let button = NSButton(image: NSImage(systemSymbolName: "rectangle", accessibilityDescription: "Exit Split View")!,
                            target: self, action: #selector(exitSplit(_:)))
      button.bezelStyle = .inline
      button.isBordered = false
      button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
      button.toolTip = "Exit Split View"
      button.setAccessibilityLabel("Exit Split View")
      button.isEnabled = false
      button.isHidden = true
      button.alphaValue = 0
      if let contentView = chromeOverlayHost { contentView.addSubview(button, positioned: .above, relativeTo: nil) }
      unsplitButtons[id] = button
    }
  }

  @objc private func exitSplit(_ sender: NSButton) {
    guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
    workspace?.endSplit(keeping: id)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    autoresizesSubviews = false
    preview.material = .hudWindow
    preview.blendingMode = .withinWindow
    preview.state = .active
    preview.wantsLayer = true
    preview.layer?.cornerRadius = BrowserLayout.contentCornerRadius
    preview.layer?.borderWidth = 1.5
    preview.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
    preview.isHidden = true
    addSubview(divider)
    addSubview(preview, positioned: .above, relativeTo: nil)
    divider.isHidden = true
    divider.setAccessibilityRole(.splitter)
    divider.setAccessibilityLabel("Resize Split View")
    divider.onDrag = { [weak self] x, finished in
      guard let self, self.split != nil else { return }
      let fraction = BrowserSplitLayout.clampedFraction(x / max(1, self.bounds.width - BrowserSplitLayout.dividerWidth),
                                                         width: self.bounds.width)
      self.resizingFraction = fraction
      self.applySurfaceLayout()
      if finished {
        self.resizingFraction = nil
        self.workspace?.setSplitFraction(fraction)
      }
    }
  }

  deinit {
    presentationAnimationTimer?.invalidate()
    if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Tracks the divider in AppKit so Chromium never handles this drag.
private final class BrowserSplitDividerView: NSView {
  var onDrag: ((CGFloat, Bool) -> Void)?
  override var isFlipped: Bool { true }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: CGRect(x: bounds.midX - 1.5, y: bounds.midY - 22, width: 3, height: 44),
                 xRadius: 1.5, yRadius: 1.5).fill()
  }

  override func mouseDown(with event: NSEvent) {
    guard let window, let superview else { return }
    let grab = convert(event.locationInWindow, from: nil).x
    NSCursor.resizeLeftRight.push()
    defer { NSCursor.pop() }
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      let x = superview.convert(next.locationInWindow, from: nil).x - grab
      let finished = next.type == .leftMouseUp
      onDrag?(x, finished)
      if finished { break }
    }
  }
}
