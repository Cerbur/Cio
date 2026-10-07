import CioEngine
import CioModel
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
  var onMinimizeSplitPane: ((UUID) -> Bool)?
  private var liftedPaneID: UUID?
  private var retainedSidebarPaneID: UUID?
  private var retainedSidebarCollapseDuration: TimeInterval?
  private var paneDropIndex: Int?
  private var isPreparingSplitDrop = false
  private var deferredRevealTabIDs = Set<UUID>()

  /// Every drag source hands off one card to the same native page reveal. The
  /// layout is committed first without an intermediate automatic restoration.
  func revealSplitPages(for tabIDs: [UUID], from windowFrame: CGRect, onCompletion: @escaping () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    deferredRevealTabIDs.formUnion(tabIDs)
    defer {
      deferredRevealTabIDs.removeAll()
      applyPlacements(targets)
      CATransaction.commit()
    }
    liftedPaneID = nil
    paneDropIndex = nil
    previewTarget = nil
    applySurfaceLayout(animatedPresentation: true, animatedVisibility: false)
    let source = convert(windowFrame, from: nil)
    let group = splitLandingFrame(for: tabIDs).map { convert($0, from: nil) }
    guard let group, source.width > 0, source.height > 0, group.width > 0, group.height > 0,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      for id in tabIDs { pages[id]?.splitTransition.cancel() }
      onCompletion()
      return
    }
    var remaining = Set(tabIDs).filter { targets[$0] != nil && pages[$0] != nil }
    guard !remaining.isEmpty else { onCompletion(); return }
    for id in Array(remaining) {
      guard let placement = targets[id], let page = pages[id] else { continue }
      page.splitTransition.reveal(from: source, into: placement.frame, group: group) { [weak self] in
        if let self { self.applyPlacements(self.targets) }
        remaining.remove(id)
        if remaining.isEmpty { onCompletion() }
      }
    }
  }

  private func startFlight(_ id: UUID, pane: CGRect,
                           from: BrowserSplitRevealTransition.Geometry,
                           to: BrowserSplitRevealTransition.Geometry,
                           direction: BrowserSplitRevealTransition.Direction, duration: TimeInterval? = nil) {
    pages[id]?.splitTransition.animate(in: pane, from: from, to: to, direction: direction, duration: duration) { [weak self] in
      guard let self else { return }
      self.applyPlacements(self.targets)
    }
  }

  private func dismissPage(_ id: UUID) {
    guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          let page = pages[id] else { return }
    page.splitTransition.dismiss { [weak self] in
      guard let self else { return }
      self.applyPlacements(self.targets)
    }
  }

  func previewPaneDrag(_ tabID: UUID?, index: Int? = nil) {
    let slot = tabID.flatMap { id in
      index ?? (liftedPaneID == id ? paneDropIndex : nil) ?? split?.tabIDs.firstIndex(of: id)
    }
    guard liftedPaneID != tabID || paneDropIndex != slot else { return }
    liftedPaneID = tabID
    paneDropIndex = slot
    applySurfaceLayout(animatedPresentation: true)
  }

  /// Keep Chromium live during the lift; the floating glass takes over as the
  /// page contracts. Native-view caching cannot reliably capture CEF content.
  func beginPaneLift(_ id: UUID, to windowFrame: CGRect) {
    guard let page = pages[id], let pane = targets[id]?.frame else { return }
    liftedPaneID = id
    paneDropIndex = split?.tabIDs.firstIndex(of: id)
    page.toolbar?.setPageControlsVisible(false, animated: true)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      var destination = BrowserSplitRevealTransition.Geometry.card(convert(windowFrame, from: nil), pane: pane, group: pane)
      destination.glassOpacity = 0
      destination.opacity = 0
      startFlight(id, pane: pane, from: page.splitTransition.source(in: pane),
                  to: destination, direction: .paneLift)
    }
    applySurfaceLayout(animatedPresentation: true)
  }

  func holdPaneForSidebar(_ id: UUID) -> CGRect? {
    guard let page = pages[id], targets[id] != nil else { return nil }
    retainedSidebarPaneID = id
    page.splitControl.setPresented(false)
    page.toolbar?.setPageControlsVisible(false, animated: true)
    return page.viewport.convert(page.viewport.bounds, to: nil)
  }

  func collapsePaneToSidebar(_ id: UUID, to windowFrame: CGRect, duration: TimeInterval) {
    guard retainedSidebarPaneID == id, let page = pages[id] else { return }
    retainedSidebarCollapseDuration = duration
    let pane = page.viewport.frame
    var destination = BrowserSplitRevealTransition.Geometry.card(convert(windowFrame, from: nil), pane: pane, group: pane)
    destination.glassOpacity = 0
    destination.opacity = 0
    // The glass and page travel continuously to the row. Keep the split until
    // the compositor midpoint, when the page has fully dissolved into glass.
    startFlight(id, pane: pane, from: page.splitTransition.source(in: pane),
                to: destination, direction: .sidebarCollapse, duration: duration)
    applySurfaceLayout()
  }

  func endPaneSidebarCollapse(_ id: UUID) {
    if retainedSidebarPaneID == id {
      retainedSidebarPaneID = nil
      retainedSidebarCollapseDuration = nil
    }
    if pages[id]?.splitTransition.direction == .sidebarCollapse || targets[id]?.toolbarVisible == true {
      pages[id]?.splitTransition.cancel()
    }
    applySurfaceLayout()
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
    if pairChanged {
      // Both directions of a split switch share replacement's departure.
      // Include the outgoing single page so it does not abruptly vanish while
      // the incoming split cards are still small.
      let previousIDs = self.split?.tabIDs ?? self.selectedTabID.map { [$0] } ?? []
      for id in previousIDs
        where !nextVisibleIDs.contains(id) && id != liftedPaneID && id != retainedSidebarPaneID && containers[id] != nil {
        dismissPage(id)
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
        // A new runtime has never had a visible page pose. Keep it hidden until
        // placement so the shared entry captures a glass card, not host.bounds.
        viewport.isHidden = true
        let page = BrowserPagePresentation(tabID: id, surface: surface, viewport: viewport)
        pages[id] = page
        page.splitControl.onDrag = { [weak self] event in self?.onSplitPaneDrag?(id, event) ?? false }
        page.onMinimizeToSidebar = { [weak self] in
          guard let self else { return }
          if self.onMinimizeSplitPane?(id) != true { self.workspace?.detachSplitPane(id) }
        }
        addSubview(page.viewport, positioned: .below, relativeTo: divider)
      }
      if let workspace, let history { pages[id]?.configureToolbar(workspace: workspace, history: history) }
      surface.setSurfaceVisible(nextVisibleIDs.contains(id) || id == retainedSidebarPaneID || pages[id]?.splitTransition.isExiting == true)
    }
    for id in Array(pages.keys) where containers[id] == nil {
      pages[id]?.splitTransition.cancel()
      guard let page = pages.removeValue(forKey: id) else { continue }
      page.hide(animated: window != nil && !isSinglePageTabSwitch)
      // Only runtime closure retires a page instance. Leave its native overlay
      // mounted until the common first-level component exit has completed.
      DispatchQueue.main.asyncAfter(deadline: .now() + AnimationValues.Toolbar.retirementDuration) {
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

  /// Insertion, replacement and pane moves all defer incoming pages until the
  /// floating card is handed off. The outgoing replacement and survivors can
  /// start immediately, retaining their existing motion and geometry.
  func commitSplitDrop(_ commit: () -> Bool) -> Bool {
    let animates = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    isPreparingSplitDrop = animates
    if animates, let liftedPaneID { deferredRevealTabIDs.insert(liftedPaneID) }
    let committed = commitSplitPreview(keepingLiftedPaneHidden: animates, commit)
    isPreparingSplitDrop = false
    if !committed {
      deferredRevealTabIDs.removeAll()
      applySurfaceLayout(animatedPresentation: true)
    }
    return committed
  }

  /// Commit directly from the current preview placement. No full-width reset,
  /// no replacement toolbar, and no reparenting of the surviving Chromium view.
  func commitSplitPreview(keepingLiftedPaneHidden: Bool = false, _ commit: () -> Bool) -> Bool {
    let hadPreview = previewTarget != nil || liftedPaneID != nil
    previewTarget = nil
    if !keepingLiftedPaneHidden { liftedPaneID = nil }
    paneDropIndex = nil
    isCommittingSplitPreview = hadPreview
    defer {
      isCommittingSplitPreview = false
      // A pane drop hands its card to the native reveal before ending the
      // preview. Retain the lift through that handoff, including reduced motion
      // and a failed drop, so clearing it always restores the final layout.
      if !keepingLiftedPaneHidden { liftedPaneID = nil }
    }
    let committed = commit()
    if !committed { applySurfaceLayout(animatedPresentation: hadPreview) }
    return committed
  }

  /// Read final geometry rather than the in-flight survivor crop. The drag
  /// overlay uses window coordinates to expand into one pane or an incoming pair.
  func splitLandingFrame(for tabIDs: [UUID]) -> CGRect? {
    guard window != nil, !tabIDs.isEmpty, let split else { return nil }
    let frames = split.paneFrames(in: bounds).panes
    var frame: CGRect?
    for id in tabIDs {
      guard let index = split.tabIDs.firstIndex(of: id) else { return nil }
      // The lifted page stays hidden through commit, so its target can be
      // absent until the card is handed back to the committed pane.
      let pane = frames[index]
      frame = frame.map { $0.union(pane) } ?? pane
    }
    return frame.map { convert($0, to: nil) }
  }

  private func applySurfaceLayout(animatedPresentation: Bool = false, animatedVisibility: Bool = true) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    var previewFrame: CGRect?
    var previewHasMaterial = false
    var dividerFrames: [CGRect] = []
    var next: [UUID: PagePlacement] = [:]
    if let id = liftedPaneID, let split, split.contains(id) {
      // A hover outside the content is not a detach. Reserve the lifted slot
      // throughout the gesture; only a committed sidebar drop removes it.
      let index = paneDropIndex ?? split.tabIDs.firstIndex(of: id)!
      let shown = split.movingPane(id, to: index)
      let frames = shown.paneFrames(in: bounds)
      dividerFrames = frames.dividers
      for (position, member) in shown.tabIDs.enumerated() {
        if member == id {
          previewFrame = frames.panes[position]
          previewHasMaterial = true
        } else {
          next[member] = PagePlacement(frame: frames.panes[position],
            roundedEdge: roundedEdge(at: position, count: shown.tabIDs.count))
        }
      }
    } else if let target = previewTarget, let split {
      let placeholderID = UUID()
      let shown = split.placingPane(placeholderID, at: target)
      let frames = shown.paneFrames(in: bounds)
      let targetIndex = shown.tabIDs.firstIndex(of: placeholderID)!
      previewFrame = frames.panes[targetIndex]
      previewHasMaterial = !target.replacesPane && split.middleTabID == nil

      dividerFrames = frames.dividers
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

        dividerFrames = frames.dividers
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
      dividerFrames = frames.dividers
      for (index, id) in split.tabIDs.enumerated() {
        next[id] = PagePlacement(frame: frames.panes[index],
                                 roundedEdge: roundedEdge(at: index, count: split.tabIDs.count))
      }
    } else if let selectedTabID, pages[selectedTabID] != nil {
      next[selectedTabID] = PagePlacement(frame: bounds)
    }
    if isPreparingSplitDrop {
      deferredRevealTabIDs.formUnion(next.keys.filter {
        targets[$0]?.toolbarVisible != true || pages[$0]?.splitTransition.isReturning == true
      })
    }
    setDividerFrames(dividerFrames)
    updatePresentationLayout(next, animated: animatedPresentation, animatedVisibility: animatedVisibility)
    updatePreviewFrame(previewFrame, hasMaterial: previewHasMaterial,
                       animated: animatedPresentation && deferredRevealTabIDs.isEmpty)
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
    for amount in BrowserSplitRevealTransition.progressSamples(.layout) {
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
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.previewFlightToken == token else { return }
        self.previewFlightToken = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.preview.layer?.removeAnimation(forKey: "split-preview-bounds")
        self.preview.layer?.removeAnimation(forKey: "split-preview-position")
        self.preview.layer?.removeAnimation(forKey: "split-preview-opacity")
        self.preview.isHidden = destination == nil
      }
    }
    for animation in [sizes, positions] {
      animation.duration = direction.duration
      animation.timingFunction = CAMediaTimingFunction(name: .linear)
      animation.beginTime = 0
      animation.fillMode = .both
      animation.isRemovedOnCompletion = false
    }
    layer.add(sizes, forKey: "split-preview-bounds")
    layer.add(positions, forKey: "split-preview-position")
    opacity.duration = direction.duration
    opacity.beginTime = 0
    layer.add(opacity, forKey: "split-preview-opacity")
    CATransaction.commit()
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
      // Layout notifications must not interpret the held contraction as a
      // returning page and replace it with a full-size reveal before commit.
      if id == retainedSidebarPaneID || deferredRevealTabIDs.contains(id) { continue }
      guard let page = pages[id] else { continue }
      if !placement.toolbarVisible {
        if targets[id]?.toolbarVisible == true { dismissPage(id) }
        continue
      }
      let returning = page.splitTransition.isReturning
      let changed = targets[id]?.frame != placement.frame || targets[id]?.toolbarVisible != true
      guard returning || changed else { continue }
      if canAnimate && (animated || returning) {
        entries[id] = page.splitTransition.source(in: placement.frame)
      }
      page.splitTransition.cancel()
    }
    targets = next
    // Establish the incoming flight's clock before resolving toolbar visibility.
    // Page and native materialize start together, rather than chaining reveals.
    for (id, source) in entries {
      guard let placement = next[id] else { continue }
      let layoutDirection: BrowserSplitRevealTransition.Direction = retainedSidebarPaneID != nil ? .sidebarSurvivor : .layout
      let duration = layoutDirection == .sidebarSurvivor && source.glassOpacity == 0
        ? retainedSidebarCollapseDuration.map { $0 * (1 - BrowserSplitRevealTransition.sidebarDetachFraction) } : nil
      startFlight(id, pane: placement.frame, from: source, to: .page(placement.frame),
        direction: source.glassOpacity > 0 ? .enter : layoutDirection, duration: duration)
    }
    applyPlacements(next, animatedVisibility: animatedVisibility && window != nil,
                    animatedLayout: canAnimate && (animated || !entries.isEmpty))
  }

  private func applyPlacements(_ next: [UUID: PagePlacement], animatedVisibility: Bool = true,
                               animatedLayout: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    // One completion barrier for the entire group, including outgoing pages.
    // Each compositor completion calls back here; only the final one reveals
    // the divider and every handle together. No guessed delay or extra flight.
    let splitControlsVisible = split != nil && liftedPaneID == nil && previewTarget == nil
      && retainedSidebarPaneID == nil && deferredRevealTabIDs.isEmpty && !isPreparingSplitDrop
      && !isCovered && workspace?.isSpotlightPresented != true
      && !pages.values.contains { $0.splitTransition.isAnimating }
    let controlRevealDuration = AnimationValues.SplitControl.revealDuration
    for view in [divider, secondDivider] {
      view.setIndicatorVisible(splitControlsVisible && !view.isHidden, duration: controlRevealDuration)
    }
    for (id, page) in pages {
      if id == retainedSidebarPaneID || deferredRevealTabIDs.contains(id) { continue }
      if page.splitTransition.isExiting {
        // Pin the outgoing Chromium size and shared parent while survivors and
        // incoming pages settle. Layout must not hide or resize this viewport.
        continue
      }
      if page.splitTransition.restoration != nil {
        page.hide(animated: false)
        continue
      }
      guard var placement = next[id], placement.toolbarVisible else {
        page.hide(animated: animatedVisibility)
        continue
      }
      if let flightFrame = page.splitTransition.frame {
        // Preview settling must not resize this viewport or Chromium while
        // their common parent is running the compositor reveal.
        placement.frame = flightFrame
      }
      if !page.splitTransition.isAnimating { applyCornerClipping(to: page.viewport, roundedEdge: placement.roundedEdge) }
      page.surface.setSurfaceVisible(true)
      page.layout(in: self, chromeHost: chromeOverlayHost, frame: placement.frame,
                  toolbarVisible: placement.toolbarVisible && !isCovered,
                  toolbarLayoutFrame: placement.frame,
                  animatedVisibility: animatedVisibility, animatedLayout: animatedLayout)
      page.splitControl.place(in: self,
        chromeHost: (chromeOverlayHost as? BrowserToolbarLayoutHosting)?.splitPaneOverlayHost,
        paneFrame: placement.frame,
        addressFrame: page.toolbar?.addressCapsuleFrame(in: self),
        visible: splitControlsVisible && split?.contains(id) == true,
        revealDuration: controlRevealDuration)
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
  private let indicator = SplitDividerIndicatorView()
  private var rolloverArea: NSTrackingArea?
  private var hovered = false
  private var dragging = false
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    indicator.boxType = .custom
    indicator.borderType = .noBorder
    indicator.titlePosition = .noTitle
    indicator.cornerRadius = 1.5
    indicator.contentViewMargins = .zero
    indicator.wantsLayer = true
    indicator.layer?.opacity = 0
    addSubview(indicator)
    updateEmphasis()
  }

  override func layout() {
    super.layout()
    let frame = CGRect(x: bounds.midX - 1.5, y: bounds.midY - 22, width: 3, height: 44)
    if indicator.frame != frame { indicator.frame = frame }
  }

  func setIndicatorVisible(_ visible: Bool, duration: TimeInterval) {
    SplitControlMotion.setVisible(visible, on: indicator.layer, duration: duration)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let rolloverArea { removeTrackingArea(rolloverArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    rolloverArea = area
    hovered = window.map {
      $0.isKeyWindow && !isHiddenOrHasHiddenAncestor
        && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
    } ?? false
    updateEmphasis()
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; updateEmphasis() }
  override func mouseExited(with event: NSEvent) { hovered = false; updateEmphasis() }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateEmphasis()
  }

  private func updateEmphasis() {
    // Match the address reload icon's black/white hover treatment, including
    // per-window appearance overrides.
    let hoverColor: NSColor = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? .white : .black
    effectiveAppearance.performAsCurrentDrawingAppearance {
      indicator.fillColor = hovered || dragging ? hoverColor
        : NSColor.separatorColor.withAlphaComponent(AnimationValues.SplitControl.dividerIdleOpacity)
    }
    SplitControlMotion.setEmphasized(hovered || dragging, on: indicator.layer,
                                    scale: AnimationValues.SplitControl.dividerHoverScale)
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

  override func mouseDown(with event: NSEvent) {
    guard let window, let superview else { return }
    let grab = convert(event.locationInWindow, from: nil).x
    dragging = true
    updateEmphasis()
    NSCursor.resizeLeftRight.push()
    defer {
      NSCursor.pop()
      dragging = false
      updateTrackingAreas()
    }
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      let x = superview.convert(next.locationInWindow, from: nil).x - grab
      let finished = next.type == .leftMouseUp
      onDrag?(x, finished)
      if finished { break }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The native rounded indicator never takes events from the full-height 8pt
/// divider hit area. Hover growth belongs solely to its visual layer.
private final class SplitDividerIndicatorView: NSBox {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
