import AppKit

/// Stable page registry and outer layout container. Each tab keeps one page UI
/// instance; this host only chooses its placement, crop and toolbar visibility.
/// BrowserSessionManager retains ownership of Chromium runtime lifetimes.
final class BrowserSurfaceHostView: NSView {
  var onDarkAppearanceChange: ((Bool) -> Void)?
  private var pages: [UUID: BrowserPagePresentation] = [:]
  private var selectedTabID: UUID?
  private var split: BrowserSplitLayout?
  private var isCovered = false
  private var previewTarget: BrowserSplitLayout.DropTarget?
  private var isCommittingSplitPreview = false
  private var resizingFraction: CGFloat?
  private var resizingSecondFraction: CGFloat?
  private var incomingPaneCount = 1
  var onSplitPaneDrag: ((UUID, BrowserSplitPaneDragEvent) -> Bool)?
  private var liftedPaneID: UUID?
  private var paneDropIndex: Int?
  private struct PageFlight {
    let token: UUID
    let frame: CGRect
    let direction: BrowserSplitRevealTransition.Direction
  }
  private var pageFlights: [UUID: PageFlight] = [:]
  private var restorationCards: [UUID: BrowserSplitRevealTransition.Geometry] = [:]

  /// The drag overlay hands its actual glass frame to the same animator used
  /// by preview changes and cancellation. Completion belongs to the flight,
  /// not the sidebar's timer, so ending a drag cannot cut another page short.
  func setSplitReveal(for tabIDs: [UUID], frame: CGRect?) {
    guard let frame, let destination = splitLandingFrame(for: tabIDs),
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let source = convert(frame, from: nil)
    let group = convert(destination, from: nil)
    guard source.width > 0, source.height > 0, group.width > 0, group.height > 0 else { return }
    for id in tabIDs {
      guard let placement = targets[id] else { continue }
      startFlight(id, pane: placement.frame,
        from: .card(source, pane: placement.frame, group: group),
        to: .page(placement.frame), direction: .enter)
    }
  }

  private func stopFlight(_ id: UUID) {
    pageFlights.removeValue(forKey: id)
    pages[id]?.endSplitRevealGlass()
    pages[id]?.viewport.layer?.removeAnimation(forKey: "split-reveal-transform")
    pages[id]?.viewport.layer?.mask = nil
    pages[id]?.viewport.layer?.zPosition = 0
  }

  /// A token invalidates stale completion when a preview is cancelled or
  /// retargeted. Capture presentation geometry BEFORE removing any animation.
  private func startFlight(_ id: UUID, pane: CGRect,
                           from: BrowserSplitRevealTransition.Geometry,
                           to: BrowserSplitRevealTransition.Geometry,
                           direction: BrowserSplitRevealTransition.Direction) {
    guard let page = pages[id], pane.width > 0, pane.height > 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    stopFlight(id)
    restorationCards.removeValue(forKey: id)
    let token = UUID()
    pageFlights[id] = PageFlight(token: token, frame: pane, direction: direction)
    BrowserSplitRevealTransition.animate(page, pane: pane, from: from, to: to, direction: direction)
    DispatchQueue.main.asyncAfter(deadline: .now() + direction.duration) { [weak self] in
      guard let self, self.pageFlights[id]?.token == token else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      self.stopFlight(id)
      if direction == .exit {
        // Keep the contracted state after hiding, so cancellation can expand
        // from the same card even after the outgoing flight has completed.
        self.restorationCards[id] = to
        page.hide(animated: false)
        page.surface.setSurfaceVisible(false)
      }
      self.applyPlacements(self.targets)
    }
  }

  private func centeredCard(in pane: CGRect) -> CGRect {
    let size = BrowserSplitRevealTransition.cardSize
    return CGRect(x: pane.midX - size.width / 2, y: pane.midY - size.height / 2,
                  width: size.width, height: size.height)
  }

  private func beginSplitExit(_ id: UUID, pane: CGRect) {
    guard pageFlights[id]?.direction != .exit, restorationCards[id] == nil,
          window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          pane.width > 0, pane.height > 0, let page = pages[id] else { return }
    let source = BrowserSplitRevealTransition.capture(page)
    page.toolbar?.setPageControlsVisible(false, animated: true)
    startFlight(id, pane: pane, from: source,
      to: .card(centeredCard(in: pane), pane: pane, group: pane), direction: .exit)
  }

  func previewPaneDrag(_ tabID: UUID?, index: Int? = nil) {
    guard liftedPaneID != tabID || paneDropIndex != index else { return }
    liftedPaneID = tabID
    paneDropIndex = index
    applySurfaceLayout(animatedPresentation: true)
  }

  private enum RoundedEdge: Equatable { case none, left, right, both }

  private struct PagePlacement: Equatable {
    var frame: CGRect
    var toolbarVisible: Bool = true
    var roundedEdge: RoundedEdge = .none
  }
  private var placements: [UUID: PagePlacement] = [:]
  private var targets: [UUID: PagePlacement] = [:]
  private weak var workspace: BrowserWorkspaceStore?
  private var history: HistoryService?
  private let divider = BrowserSplitDividerView()
  private let secondDivider = BrowserSplitDividerView()
  private let preview = BrowserSplitPreviewView()
  private var previewFrameTarget: CGRect?
  private var previewMaterialTarget = false
  private var previewFlightToken: UUID?
  nonisolated(unsafe) private var paneClickMonitor: Any?

  private var chromeOverlayHost: NSView? {
    var ancestor = superview
    while let candidate = ancestor {
      if candidate is BrowserToolbarLayoutHosting { return candidate }
      ancestor = candidate.superview
    }
    return nil
  }

  override var isFlipped: Bool { true }

  func syncChromiumAppearance() {
    guard window != nil else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    CEFProcessHost.setDarkAppearance(dark)
    onDarkAppearanceChange?(dark)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncChromiumAppearance()
    needsLayout = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncChromiumAppearance()
  }

  func configure(workspace: BrowserWorkspaceStore, history: HistoryService) {
    self.workspace = workspace
    self.history = history
    for page in pages.values { page.configureToolbar(workspace: workspace, history: history) }
    if paneClickMonitor == nil {
      paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        guard let self, event.window === self.window, let split = self.split,
              !self.isCovered, self.workspace?.isSpotlightPresented != true, self.preview.isHidden else { return event }
        let point = self.convert(event.locationInWindow, from: nil)
        guard self.bounds.contains(point) else { return event }
        let frames = split.paneFrames(in: self.bounds)
        if let index = frames.panes.firstIndex(where: { $0.contains(point) }) {
          self.workspace?.selectTab(id: split.tabIDs[index])
        }
        return event
      }
    }
  }

  func setPresentationCovered(_ covered: Bool) {
    guard isCovered != covered else { return }
    isCovered = covered
    applyPlacements(placements, animatedVisibility: true)
  }

  func present(containers: [UUID: ChromiumContainerView], selectedTabID: UUID?, split: BrowserSplitLayout? = nil) {
    let pairChanged = self.split?.tabIDs != split?.tabIDs
    let nextVisibleIDs = Set(split?.tabIDs ?? selectedTabID.map { [$0] } ?? [])
    if let previous = self.split {
      let frames = previous.paneFrames(in: bounds).panes
      for (index, id) in previous.tabIDs.enumerated()
        where !nextVisibleIDs.contains(id) && id != liftedPaneID && containers[id] != nil {
        beginSplitExit(id, pane: frames[index])
      }
    }
    // A single-page tab switch replaces the toolbar in its existing slot. Both
    // tab-owned instances stay alive, but neither plays an exit/entry animation.
    // Split changes and drag previews still use the component visibility contract.
    let isSinglePageTabSwitch = self.split == nil && split == nil
      && previewTarget == nil && !isCommittingSplitPreview
      && self.selectedTabID != nil && selectedTabID != nil
      && self.selectedTabID != selectedTabID
    self.selectedTabID = selectedTabID
    self.split = split
    // Identity follows live tabs, never pane count, selected section or split ID.
    // Every surface is mounted once in its viewport before CEF attaches to it.
    for (id, surface) in containers {
      if pages[id] == nil {
        let viewport = BrowserPageViewportView(frame: surface.frame)
        let page = BrowserPagePresentation(tabID: id, surface: surface, viewport: viewport)
        pages[id] = page
        page.splitControl.onDrag = { [weak self] event in self?.onSplitPaneDrag?(id, event) ?? false }
        addSubview(page.viewport, positioned: .below, relativeTo: divider)
      }
      if let workspace, let history { pages[id]?.configureToolbar(workspace: workspace, history: history) }
      surface.setSurfaceVisible(nextVisibleIDs.contains(id) || pageFlights[id]?.direction == .exit)
    }
    for id in Array(pages.keys) where containers[id] == nil {
      stopFlight(id)
      restorationCards.removeValue(forKey: id)
      guard let page = pages.removeValue(forKey: id) else { continue }
      page.hide(animated: window != nil && !isSinglePageTabSwitch)
      // Only runtime closure retires a page instance. Leave its native overlay
      // mounted until the common first-level component exit has completed.
      DispatchQueue.main.asyncAfter(deadline: .now() + ToolbarComponentAnimation.duration + 0.05) {
        page.dispose()
      }
    }
    applySurfaceLayout(animatedPresentation: isCommittingSplitPreview || pairChanged,
                       animatedVisibility: !isSinglePageTabSwitch)
  }

  override func layout() {
    super.layout()
    applySurfaceLayout()
  }

  func previewSplit(at target: BrowserSplitLayout.DropTarget?, incomingPaneCount: Int = 1) {
    guard previewTarget != target || self.incomingPaneCount != incomingPaneCount else { return }
    previewTarget = target
    self.incomingPaneCount = incomingPaneCount
    applySurfaceLayout(animatedPresentation: true)
  }

  /// Commit directly from the current preview placement. No full-width reset,
  /// no replacement toolbar, and no reparenting of the surviving Chromium view.
  func commitSplitPreview(_ commit: () -> Bool) -> Bool {
    let hadPreview = previewTarget != nil || liftedPaneID != nil
    previewTarget = nil
    liftedPaneID = nil
    paneDropIndex = nil
    isCommittingSplitPreview = hadPreview
    defer { isCommittingSplitPreview = false }
    let committed = commit()
    if !committed { applySurfaceLayout(animatedPresentation: hadPreview) }
    return committed
  }

  /// Read final geometry rather than the in-flight survivor crop. The drag
  /// overlay uses window coordinates to expand into one pane or an incoming pair.
  func splitLandingFrame(for tabIDs: [UUID]) -> CGRect? {
    guard window != nil, !tabIDs.isEmpty else { return nil }
    var frame: CGRect?
    for id in tabIDs {
      guard split?.contains(id) == true, let target = targets[id] else { return nil }
      frame = frame.map { $0.union(target.frame) } ?? target.frame
    }
    return frame.map { convert($0, to: nil) }
  }

  private func applySurfaceLayout(animatedPresentation: Bool = false, animatedVisibility: Bool = true) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    var previewFrame: CGRect?
    var previewHasMaterial = false
    setDividerFrames([])
    var next: [UUID: PagePlacement] = [:]
    if let id = liftedPaneID, let split, split.contains(id) {
      if let index = paneDropIndex {
        let shown = split.movingPane(id, to: index)
        let frames = shown.paneFrames(in: bounds)
        setDividerFrames(frames.dividers)
        for (position, member) in shown.tabIDs.enumerated() {
          if member == id {
            previewFrame = frames.panes[position]
            previewHasMaterial = true

          } else {
            next[member] = PagePlacement(frame: frames.panes[position],
              roundedEdge: roundedEdge(at: position, count: shown.tabIDs.count))
          }
        }
      } else {
        let remaining = split.tabIDs.filter { $0 != id }
        if remaining.count == 2 {
          let shown = BrowserSplitLayout(leftTabID: remaining[0], rightTabID: remaining[1])
          let frames = shown.paneFrames(in: bounds)
          setDividerFrames(frames.dividers)
          for (position, member) in remaining.enumerated() {
            next[member] = PagePlacement(frame: frames.panes[position],
              roundedEdge: roundedEdge(at: position, count: 2))
          }
        } else if let member = remaining.first {
          next[member] = PagePlacement(frame: bounds)
        }
      }
    } else if let target = previewTarget, let split {
      let placeholderID = UUID()
      let shown = split.placingPane(placeholderID, at: target)
      let frames = shown.paneFrames(in: bounds)
      let targetIndex = shown.tabIDs.firstIndex(of: placeholderID)!
      previewFrame = frames.panes[targetIndex]
      previewHasMaterial = !target.replacesPane && split.middleTabID == nil

      setDividerFrames(frames.dividers)
      for id in split.tabIDs {
        if !previewHasMaterial, let index = split.tabIDs.firstIndex(of: id) {
          // Replacement highlights the live page until release. Hovering must
          // not hide it, contract it into a card, or change either divider.
          next[id] = PagePlacement(frame: frames.panes[index],
            roundedEdge: roundedEdge(at: index, count: frames.panes.count))
        } else if let destination = shown.tabIDs.firstIndex(of: id) {
          next[id] = PagePlacement(frame: frames.panes[destination],
            roundedEdge: roundedEdge(at: destination, count: frames.panes.count))
        } else {
          next[id] = PagePlacement(frame: collapsedFrame(for: id), toolbarVisible: false)
        }
      }
    } else if let target = previewTarget, let selectedTabID {
      let side = target.side
      if side == .middle {
        // The central return zone preserves the full-page presentation.
        previewFrame = bounds

        next[selectedTabID] = PagePlacement(frame: bounds)
      } else if incomingPaneCount == 2 {
        previewHasMaterial = true
        let shown = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: 1.0 / 3,
                                       middleTabID: UUID(), secondFraction: 2.0 / 3)
        let frames = shown.paneFrames(in: bounds)
        let survivorIndex = side == .left ? 2 : 0
        previewFrame = side == .left ? frames.panes[0].union(frames.panes[1])
          : frames.panes[1].union(frames.panes[2])

        setDividerFrames(frames.dividers)
        next[selectedTabID] = PagePlacement(frame: frames.panes[survivorIndex],
          roundedEdge: roundedEdge(at: survivorIndex, count: 3))
      } else {
        previewHasMaterial = true
        let frames = BrowserSplitLayout.previewFrames(in: bounds, on: side,
          maximumSurvivorWidth: pages[selectedTabID]?.surface.frame.width ?? bounds.width)
        previewFrame = frames.target

        next[selectedTabID] = PagePlacement(frame: frames.survivor,
          roundedEdge: side == .left ? .left : .right)
      }
    } else if let split {
      var shown = split
      shown.fraction = resizingFraction ?? split.fraction
      shown.secondFraction = resizingSecondFraction ?? split.secondFraction
      let frames = shown.paneFrames(in: bounds)
      setDividerFrames(frames.dividers)
      for (index, id) in split.tabIDs.enumerated() {
        next[id] = PagePlacement(frame: frames.panes[index],
                                 roundedEdge: roundedEdge(at: index, count: split.tabIDs.count))
      }
    } else if let selectedTabID, pages[selectedTabID] != nil {
      next[selectedTabID] = PagePlacement(frame: bounds)
    }
    updatePresentationLayout(next, animated: animatedPresentation, animatedVisibility: animatedVisibility)
    updatePreviewFrame(previewFrame, hasMaterial: previewHasMaterial, animated: animatedPresentation)
  }

  /// Grow the native drop region from the outer edge while the survivor loses
  /// exactly that width. Use the page motion curve and duration so both sides
  /// of the boundary travel together; cancel from the current visible frame.
  private func updatePreviewFrame(_ destination: CGRect?, hasMaterial: Bool, animated: Bool) {
    guard previewFrameTarget != destination || previewMaterialTarget != hasMaterial else { return }
    let previous = previewFrameTarget
    let hadMaterial = previewMaterialTarget
    previewFrameTarget = destination
    previewMaterialTarget = hasMaterial
    guard let layer = preview.layer else { return }
    let shown = preview.isHidden ? nil : (layer.presentation() ?? layer).frame
    let shownOpacity = preview.isHidden ? 0 : (layer.presentation() ?? layer).opacity
    layer.removeAnimation(forKey: "split-preview-bounds")
    layer.removeAnimation(forKey: "split-preview-position")
    layer.removeAnimation(forKey: "split-preview-opacity")
    let token = UUID()
    previewFlightToken = token
    let canAnimate = animated && !isCommittingSplitPreview && window != nil
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    preview.setMaterialVisible(destination == nil ? hadMaterial : hasMaterial)
    layer.opacity = destination == nil ? 0 : 1
    guard canAnimate, let region = destination ?? previous else {
      preview.isHidden = destination == nil
      if let destination { preview.frame = destination }
      if let destination { preview.prepareMaterial(size: destination.size) }
      return
    }
    let insertionOrigin: CGFloat
    if region.minX <= bounds.minX { insertionOrigin = bounds.minX }
    else if region.maxX >= bounds.maxX { insertionOrigin = bounds.maxX - 1 }
    else { insertionOrigin = split?.paneFrames(in: bounds).dividers.first?.midX ?? region.midX }
    let collapsed = CGRect(x: insertionOrigin,
                           y: region.minY, width: 1, height: region.height)
    let source = shown ?? (hasMaterial ? collapsed : region)
    let final = destination ?? (hadMaterial ? collapsed : region)
    preview.frame = final
    preview.prepareMaterial(size: CGSize(width: max(source.width, final.width), height: final.height))
    preview.isHidden = false
    // Only the compositor resizes the crop and its native continuous border.
    // The backdrop stays at a fixed size, avoiding AppKit material relayout on
    // every frame of NSView.animator().frame. Chromium follows the same clock.
    let anchor = layer.anchorPoint
    let offset = CGPoint(x: layer.position.x - final.minX - anchor.x * final.width,
                         y: layer.position.y - final.minY - anchor.y * final.height)
    let sizes = CAKeyframeAnimation(keyPath: "bounds")
    let positions = CAKeyframeAnimation(keyPath: "position")
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = shownOpacity
    opacity.toValue = layer.opacity
    opacity.timingFunction = BrowserSplitRevealTransition.Direction.layout.timingFunction
    var boundsValues: [NSValue] = []
    var positionValues: [NSValue] = []
    for amount in BrowserSplitRevealTransition.progressSamples(.enter) {
      func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
      let frame = CGRect(x: blend(source.minX, final.minX), y: blend(source.minY, final.minY),
                         width: blend(source.width, final.width), height: blend(source.height, final.height))
      boundsValues.append(NSValue(rect: CGRect(origin: layer.bounds.origin, size: frame.size)))
      positionValues.append(NSValue(point: CGPoint(x: frame.minX + anchor.x * frame.width + offset.x,
                                                  y: frame.minY + anchor.y * frame.height + offset.y)))
    }
    sizes.values = boundsValues
    positions.values = positionValues
    let direction = BrowserSplitRevealTransition.Direction.layout
    let beginTime = CACurrentMediaTime()
    for animation in [sizes, positions] {
      animation.duration = direction.duration
      animation.timingFunction = CAMediaTimingFunction(name: .linear)
      animation.beginTime = beginTime
      animation.fillMode = .both
      animation.isRemovedOnCompletion = false
    }
    layer.add(sizes, forKey: "split-preview-bounds")
    layer.add(positions, forKey: "split-preview-position")
    opacity.duration = direction.duration
    opacity.beginTime = beginTime
    layer.add(opacity, forKey: "split-preview-opacity")
    DispatchQueue.main.asyncAfter(deadline: .now() + direction.duration) { [weak self] in
      guard let self, self.previewFlightToken == token else { return }
      self.previewFlightToken = nil
      self.preview.layer?.removeAnimation(forKey: "split-preview-bounds")
      self.preview.layer?.removeAnimation(forKey: "split-preview-position")
      self.preview.layer?.removeAnimation(forKey: "split-preview-opacity")
      self.preview.isHidden = destination == nil
    }
  }

  private func roundedEdge(at index: Int, count: Int) -> RoundedEdge {
    index == 0 ? .right : (index == count - 1 ? .left : .both)
  }

  private func setDividerFrames(_ frames: [CGRect]) {
    for (index, view) in [divider, secondDivider].enumerated() {
      view.isHidden = index >= frames.count
      if index < frames.count { view.frame = frames[index] }
    }
  }

  private func collapsedFrame(for id: UUID) -> CGRect {
    let frame = placements[id]?.frame ?? pages[id]?.viewport.frame ?? .zero
    return CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0)
  }

  /// Final layout is assigned up front. Every split layout/restore uses the
  /// same compositor flight, replacing the old per-frame crop/resize timer.
  private func updatePresentationLayout(_ next: [UUID: PagePlacement], animated: Bool, animatedVisibility: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let canAnimate = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var entries: [UUID: BrowserSplitRevealTransition.Geometry] = [:]
    for (id, placement) in next {
      guard let page = pages[id] else { continue }
      if !placement.toolbarVisible {
        if let previous = targets[id], previous.toolbarVisible { beginSplitExit(id, pane: previous.frame) }
        continue
      }
      let returning = restorationCards[id] != nil || pageFlights[id]?.direction == .exit
      let changed = targets[id]?.frame != placement.frame || targets[id]?.toolbarVisible != true
      guard returning || changed else { continue }
      if canAnimate && (animated || returning) {
        var source: BrowserSplitRevealTransition.Geometry
        if let card = restorationCards[id] {
          source = card
        } else if !page.viewport.isHidden, page.viewport.frame.width > 0, page.viewport.frame.height > 0 {
          source = BrowserSplitRevealTransition.capture(page)
          // Keep any material already visible during an interrupted reveal.
          // Width-only survivor motion needs no extra live glass backdrop.
        } else {
          source = .card(centeredCard(in: placement.frame), pane: placement.frame, group: placement.frame)
        }
        entries[id] = source
      }
      stopFlight(id)
      restorationCards.removeValue(forKey: id)
    }
    targets = next
    applyPlacements(next, animatedVisibility: animatedVisibility && window != nil)
    for (id, source) in entries {
      guard let placement = next[id] else { continue }
      startFlight(id, pane: placement.frame, from: source, to: .page(placement.frame),
        direction: source.glassOpacity > 0 ? .enter : .layout)
    }
  }

  private func applyPlacements(_ next: [UUID: PagePlacement], animatedVisibility: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for (id, page) in pages {
      if pageFlights[id]?.direction == .exit {
        // Pin the outgoing Chromium size and shared parent while survivors and
        // incoming pages settle. Layout must not hide or resize this viewport.
        continue
      }
      if restorationCards[id] != nil {
        page.hide(animated: false)
        continue
      }
      guard var placement = next[id], placement.toolbarVisible else {
        page.hide(animated: animatedVisibility)
        continue
      }
      if let flight = pageFlights[id] {
        // Preview settling must not resize this viewport or Chromium while
        // their common parent is running the compositor reveal.
        placement.frame = flight.frame
      }
      if pageFlights[id] == nil { applyCornerClipping(to: page.viewport, roundedEdge: placement.roundedEdge) }
      page.surface.setSurfaceVisible(true)
      page.layout(in: self, chromeHost: chromeOverlayHost, frame: placement.frame,
                  toolbarVisible: placement.toolbarVisible && !isCovered,
                  toolbarLayoutFrame: placement.frame,
                  animatedVisibility: animatedVisibility)
      page.splitControl.place(in: self,
        chromeHost: (chromeOverlayHost as? BrowserToolbarLayoutHosting)?.splitPaneOverlayHost,
        paneFrame: placement.frame,
        addressFrame: page.toolbar?.addressCapsuleFrame(in: self),
        visible: split?.contains(id) == true && pageFlights[id] == nil
          && liftedPaneID == nil && previewTarget == nil && !isCovered
          && workspace?.isSpotlightPresented != true)
    }
    placements = next
  }

  /// Main View owns the shell's outside corners. This splitter host owns only
  /// the two corners on each page's divider-facing edge. The preview region
  /// owns a complete four-corner outline so its accent border remains visible.
  /// A single page has no extra rounded mask. Chromium receives rectangular
  /// layout bounds only; its layer and bridge never receive a clipping policy.
  private func applyCornerClipping(to viewport: NSView, roundedEdge: RoundedEdge) {
    guard let layer = viewport.layer else { return }
    layer.cornerRadius = roundedEdge == .none ? 0 : BrowserLayout.contentCornerRadius
    switch roundedEdge {
    case .none: layer.maskedCorners = []
    case .left: layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    case .right: layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    case .both: layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner,
                                      .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    autoresizesSubviews = false
    preview.isHidden = true
    addSubview(divider)
    addSubview(secondDivider)
    addSubview(preview, positioned: .above, relativeTo: nil)
    for (index, view) in [divider, secondDivider].enumerated() {
      view.isHidden = true
      view.setAccessibilityRole(.splitter)
      view.setAccessibilityLabel("Resize Split View \(index + 1)")
      view.onDrag = { [weak self] x, finished in
        guard let self, let split = self.split else { return }
        let dividerCount = split.tabIDs.count - 1
        let usable = max(1, self.bounds.width - CGFloat(dividerCount) * BrowserSplitLayout.dividerWidth)
        let proposed = (x - CGFloat(index) * BrowserSplitLayout.dividerWidth) / usable
        let fraction: CGFloat
        if split.middleTabID != nil {
          let minimum = min(1.0 / 3, BrowserSplitLayout.minimumPaneWidth / usable)
          let current = split.clampedFractions(width: self.bounds.width)
          fraction = index == 0 ? min(max(proposed, minimum), current.second - minimum)
            : min(max(proposed, current.first + minimum), 1 - minimum)
        } else {
          fraction = BrowserSplitLayout.clampedFraction(proposed, width: self.bounds.width)
        }
        if index == 0 { self.resizingFraction = fraction }
        else { self.resizingSecondFraction = fraction }
        self.applySurfaceLayout()
        if finished {
          self.resizingFraction = nil
          self.resizingSecondFraction = nil
          self.workspace?.setSplitFraction(fraction, divider: index)
        }
      }
    }
  }

  deinit {
    if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The region has all four native continuous corners, matching Main View's
/// radius even where its outer edges touch the shell clip. Rounding only the
/// divider-facing corners leaves a square border for Main View to cut off.
private final class BrowserSplitPreviewView: NSView {
  private let material = NSVisualEffectView()
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    autoresizesSubviews = false
    layer?.cornerRadius = BrowserLayout.contentCornerRadius
    layer?.cornerCurve = .continuous
    layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner,
                            .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    layer?.masksToBounds = true
    layer?.borderWidth = 1.5
    layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
    material.material = .hudWindow
    material.blendingMode = .withinWindow
    material.state = .active
    material.autoresizingMask = []
    addSubview(material)
  }

  func prepareMaterial(size: CGSize) {
    // Retain the largest region width so shrinking/cancelling never rebuilds
    // the backdrop. Only a larger target or a window-height change resizes it.
    let frame = CGRect(origin: .zero, size: CGSize(width: max(material.frame.width, size.width), height: size.height))
    if material.frame != frame { material.frame = frame }
  }

  func setMaterialVisible(_ visible: Bool) {
    material.isHidden = !visible
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Splitter-owned rectangular crop. The host assigns divider-facing rounded
/// edges from its placement map without changing the Chromium child hierarchy.
private final class BrowserPageViewportView: NSView {
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    autoresizesSubviews = false
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
