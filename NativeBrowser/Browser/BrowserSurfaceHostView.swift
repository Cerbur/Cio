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
  nonisolated(unsafe) private var toolbarAnimationTimer: Timer?
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
    for toolbar in toolbars.values { toolbar.setSpaceControlsVisible(!covered, animated: false) }
    for button in unsplitButtons.values { button.isHidden = covered }
  }

  func present(containers: [UUID: ChromiumContainerView], selectedTabID: UUID?, split: BrowserSplitLayout? = nil) {
    self.containers = containers
    self.selectedTabID = selectedTabID
    let pairChanged = self.split?.tabIDs != split?.tabIDs
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
    applySurfaceLayout(animatedToolbar: isCommittingSplitPreview)
  }

  override func layout() {
    super.layout()
    applySurfaceLayout()
  }

  /// Preview changes origins and layer masks only. No Chromium view changes size.
  func previewSplit(on side: BrowserSplitLayout.Side?) {
    guard previewSide != side else { return }
    previewSide = side
    applySurfaceLayout(animatedToolbar: true)
  }

  /// Consume the preview without first presenting the full-width page. The
  /// workspace publishes the committed pair synchronously inside this closure.
  func commitSplitPreview(_ commit: () -> Bool) -> Bool {
    let hadPreview = previewSide != nil
    if hadPreview, let selectedTabID {
      // Transfer the shell's current animated frame to the surviving pane's
      // toolbar, including a drop before the preview animation has finished.
      toolbarFrames[selectedTabID] = selectedToolbarFrame ?? bounds
    }
    previewSide = nil
    isCommittingSplitPreview = hadPreview
    defer { isCommittingSplitPreview = false }
    let committed = commit()
    if !committed { applySurfaceLayout(animatedToolbar: hadPreview) }
    return committed
  }

  private func applySurfaceLayout(animatedToolbar: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    preview.isHidden = previewSide == nil
    if let side = previewSide {
      let currentWidth = selectedTabID.flatMap { containers[$0]?.frame.width } ?? bounds.width
      let frames = BrowserSplitLayout.previewFrames(in: bounds, on: side,
                                                   maximumSurvivorWidth: currentWidth)
      preview.frame = frames.target
      divider.isHidden = true
      for (id, container) in containers where container.isSurfaceVisible {
        // Keep every Chromium surface at its committed size during tab placement.
        place(container, in: id == selectedTabID ? frames.survivor : .zero, cropOnly: true)
      }
      let paneFrames = toolbars.keys.filter { $0 == selectedTabID }
        .reduce(into: [UUID: CGRect]()) { $0[$1] = frames.survivor }
      updateToolbarLayout(panes: paneFrames, selectedFrame: frames.survivor, animated: animatedToolbar)
    } else if let split {
      var shown = split
      shown.fraction = resizingFraction ?? split.fraction
      let frames = shown.frames(in: bounds)
      for (id, frame) in [(split.leftTabID, frames.left), (split.rightTabID, frames.right)] {
        guard let container = containers[id] else { continue }
        // Divider drags resize Chromium immediately so responsive page layout
        // previews at the actual pane width, rather than cropping the old page.
        place(container, in: frame, cropOnly: false)
      }
      divider.frame = frames.divider
      divider.isHidden = false
      updateToolbarLayout(panes: [split.leftTabID: frames.left, split.rightTabID: frames.right],
                          selectedFrame: nil, animated: animatedToolbar)
    } else {
      divider.isHidden = true
      if let selectedTabID, let container = containers[selectedTabID] {
        place(container, in: bounds, cropOnly: false)
      }
      updateToolbarLayout(panes: [:], selectedFrame: nil, animated: animatedToolbar)
    }
    // Inactive containers keep their last committed geometry and their live page.
  }

  /// Interpolate only toolbar geometry. Chromium crops/resizes keep their own
  /// timing, and splitter tracking continues to update page widths immediately.
  private func updateToolbarLayout(panes: [UUID: CGRect], selectedFrame: CGRect?, animated: Bool) {
    guard panes != toolbarTargetFrames || selectedFrame != selectedToolbarTargetFrame else {
      // Layout may be repeated while a window or overlay is being attached.
      // Preserve an active transition; otherwise refresh the mounted controls.
      if toolbarAnimationTimer == nil { applyToolbarLayout(panes: panes, selectedFrame: selectedFrame) }
      return
    }
    toolbarTargetFrames = panes
    selectedToolbarTargetFrame = selectedFrame
    toolbarAnimationTimer?.invalidate()
    toolbarAnimationTimer = nil
    for id in toolbars.keys where panes[id] == nil {
      layoutToolbar(for: id, in: toolbarFrames[id] ?? bounds, visible: false)
    }
    guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      applyToolbarLayout(panes: panes, selectedFrame: selectedFrame)
      return
    }
    let startFrames = toolbarFrames
    let startSelected = selectedToolbarFrame ?? bounds
    let endSelected = selectedFrame ?? bounds
    // Newly mounted pane controls must start at the transferred preview frame
    // immediately, rather than drawing their default frame until the first tick.
    let initialFrames = panes.map { id, end in (id, startFrames[id] ?? end) }
    applyToolbarLayout(panes: Dictionary(uniqueKeysWithValues: initialFrames), selectedFrame: startSelected)
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
        self.applyToolbarLayout(panes: Dictionary(uniqueKeysWithValues: current),
          selectedFrame: progress == 1 ? selectedFrame : Self.interpolatedFrame(
            from: startSelected, to: endSelected, amount: amount))
        if progress == 1 {
          self.toolbarAnimationTimer?.invalidate()
          self.toolbarAnimationTimer = nil
        }
      }
    }
    toolbarAnimationTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func applyToolbarLayout(panes: [UUID: CGRect], selectedFrame: CGRect?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    toolbarFrames = panes
    selectedToolbarFrame = selectedFrame
    for (id, frame) in panes { layoutToolbar(for: id, in: frame, visible: true) }
    onSelectedSurfaceFrameChange?(selectedFrame)
  }

  private static func interpolatedFrame(from start: CGRect, to end: CGRect, amount: CGFloat) -> CGRect {
    CGRect(x: start.minX + (end.minX - start.minX) * amount,
           y: start.minY + (end.minY - start.minY) * amount,
           width: start.width + (end.width - start.width) * amount,
           height: start.height + (end.height - start.height) * amount)
  }

  private func layoutToolbar(for id: UUID, in frame: CGRect, visible: Bool) {
    guard let toolbar = toolbars[id] else { return }
    toolbar.setSpaceControlsVisible(visible && !isCovered, animated: false)
    unsplitButtons[id]?.isHidden = !visible || isCovered
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

  private func place(_ container: ChromiumContainerView, in frame: CGRect, cropOnly: Bool) {
    if cropOnly {
      container.setFrameOrigin(frame.origin)
      let mask = CALayer()
      mask.backgroundColor = NSColor.black.cgColor
      mask.frame = CGRect(origin: .zero, size: frame.size)
      container.layer?.mask = mask
    } else {
      container.layer?.mask = nil
      if container.frame != frame { container.frame = frame }
    }
  }

  private func rebuildToolbars() {
    for toolbar in toolbars.values { toolbar.removeFromPresentation() }
    for guide in toolbarGuides.values { guide.removeFromSuperview() }
    for button in unsplitButtons.values { button.removeFromSuperview() }
    toolbars.removeAll()
    toolbarGuides.removeAll()
    unsplitButtons.removeAll()
    guard let split, let workspace, let history else { return }
    for id in split.tabIDs {
      let guide = NSView()
      guide.isHidden = true
      addSubview(guide)
      toolbarGuides[id] = guide
      let toolbar = BrowserToolbarController(workspace: workspace, history: history, browserView: guide,
        isSidebarCollapsed: { true }, onSidebarToggle: {}, tabID: id)
      if let contentView = chromeOverlayHost { contentView.addSubview(toolbar.view, positioned: .above, relativeTo: nil) }
      toolbars[id] = toolbar
      if let window { toolbar.install(in: window, showsSpaceToolbar: !isCovered) }
      let button = NSButton(image: NSImage(systemSymbolName: "rectangle", accessibilityDescription: "Exit Split View")!,
                            target: self, action: #selector(exitSplit(_:)))
      button.bezelStyle = .inline
      button.isBordered = false
      button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
      button.toolTip = "Exit Split View"
      button.setAccessibilityLabel("Exit Split View")
      button.isHidden = isCovered
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
    toolbarAnimationTimer?.invalidate()
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
