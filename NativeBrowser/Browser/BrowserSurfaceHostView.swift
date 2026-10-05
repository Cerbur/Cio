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

  func previewPaneDrag(_ tabID: UUID?, index: Int? = nil) {
    guard liftedPaneID != tabID || paneDropIndex != index else { return }
    liftedPaneID = tabID
    paneDropIndex = index
    applySurfaceLayout(animatedPresentation: true)
  }

  private enum RoundedEdge: Equatable { case none, left, right, both }

  private struct PagePlacement: Equatable {
    var frame: CGRect
    var cropOnly: Bool
    var toolbarVisible: Bool = true
    var roundedEdge: RoundedEdge = .none
  }
  private var placements: [UUID: PagePlacement] = [:]
  private var targets: [UUID: PagePlacement] = [:]
  /// Returning controls materialize at their final placement even while their
  /// previously collapsed content crop is still expanding from a preview.
  private var appearingToolbarFrames: [UUID: CGRect] = [:]
  nonisolated(unsafe) private var presentationAnimationTimer: Timer?
  private weak var workspace: BrowserWorkspaceStore?
  private var history: HistoryService?
  private let divider = BrowserSplitDividerView()
  private let secondDivider = BrowserSplitDividerView()
  private let preview = NSVisualEffectView()
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
    if !covered, presentationAnimationTimer != nil {
      for (id, target) in targets where target.toolbarVisible {
        appearingToolbarFrames[id] = target.frame
      }
    }
    applyPlacements(placements, animatedVisibility: true)
  }

  func present(containers: [UUID: ChromiumContainerView], selectedTabID: UUID?, split: BrowserSplitLayout? = nil) {
    let pairChanged = self.split?.tabIDs != split?.tabIDs
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
      surface.setSurfaceVisible(split?.contains(id) ?? (id == selectedTabID))
    }
    for id in Array(pages.keys) where containers[id] == nil {
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
    let hadPreview = previewTarget != nil
    previewTarget = nil
    isCommittingSplitPreview = hadPreview
    defer { isCommittingSplitPreview = false }
    let committed = commit()
    if !committed { applySurfaceLayout(animatedPresentation: hadPreview) }
    return committed
  }

  private func applySurfaceLayout(animatedPresentation: Bool = false, animatedVisibility: Bool = true) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    preview.isHidden = previewTarget == nil && !(liftedPaneID != nil && paneDropIndex != nil)
    setDividerFrames([])
    var next: [UUID: PagePlacement] = [:]
    if let id = liftedPaneID, let split, split.contains(id) {
      if let index = paneDropIndex {
        let shown = split.movingPane(id, to: index)
        let frames = shown.paneFrames(in: bounds)
        setDividerFrames(frames.dividers)
        for (position, member) in shown.tabIDs.enumerated() {
          if member == id {
            preview.frame = frames.panes[position]
            applyCornerClipping(to: preview, roundedEdge: roundedEdge(at: position, count: shown.tabIDs.count))
          } else {
            next[member] = PagePlacement(frame: frames.panes[position], cropOnly: true,
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
            next[member] = PagePlacement(frame: frames.panes[position], cropOnly: true,
              roundedEdge: roundedEdge(at: position, count: 2))
          }
        } else if let member = remaining.first {
          next[member] = PagePlacement(frame: bounds, cropOnly: true)
        }
      }
    } else if let target = previewTarget, let split {
      let placeholderID = UUID()
      let shown = split.placingPane(placeholderID, at: target)
      let frames = shown.paneFrames(in: bounds)
      let targetIndex = shown.tabIDs.firstIndex(of: placeholderID)!
      preview.frame = frames.panes[targetIndex]
      applyCornerClipping(to: preview, roundedEdge: roundedEdge(at: targetIndex, count: frames.panes.count))
      setDividerFrames(frames.dividers)
      for id in split.tabIDs {
        if let destination = shown.tabIDs.firstIndex(of: id) {
          next[id] = PagePlacement(frame: frames.panes[destination], cropOnly: true,
            roundedEdge: roundedEdge(at: destination, count: frames.panes.count))
        } else {
          next[id] = PagePlacement(frame: collapsedFrame(for: id), cropOnly: true, toolbarVisible: false)
        }
      }
    } else if let target = previewTarget, let selectedTabID {
      let side = target.side
      if side == .middle {
        // The central return zone preserves the full-page presentation.
        preview.frame = bounds
        applyCornerClipping(to: preview, roundedEdge: .none)
        next[selectedTabID] = PagePlacement(frame: bounds, cropOnly: true)
      } else if incomingPaneCount == 2 {
        let shown = BrowserSplitLayout(leftTabID: UUID(), rightTabID: UUID(), fraction: 1.0 / 3,
                                       middleTabID: UUID(), secondFraction: 2.0 / 3)
        let frames = shown.paneFrames(in: bounds)
        let survivorIndex = side == .left ? 2 : 0
        preview.frame = side == .left ? frames.panes[0].union(frames.panes[1])
          : frames.panes[1].union(frames.panes[2])
        applyCornerClipping(to: preview, roundedEdge: side == .left ? .right : .left)
        setDividerFrames(frames.dividers)
        next[selectedTabID] = PagePlacement(frame: frames.panes[survivorIndex], cropOnly: true,
          roundedEdge: roundedEdge(at: survivorIndex, count: 3))
      } else {
        let frames = BrowserSplitLayout.previewFrames(in: bounds, on: side,
          maximumSurvivorWidth: pages[selectedTabID]?.surface.frame.width ?? bounds.width)
        preview.frame = frames.target
        applyCornerClipping(to: preview, roundedEdge: side == .left ? .right : .left)
        next[selectedTabID] = PagePlacement(frame: frames.survivor, cropOnly: true,
          roundedEdge: side == .left ? .left : .right)
      }
    } else if let split {
      var shown = split
      shown.fraction = resizingFraction ?? split.fraction
      shown.secondFraction = resizingSecondFraction ?? split.secondFraction
      let frames = shown.paneFrames(in: bounds)
      setDividerFrames(frames.dividers)
      for (index, id) in split.tabIDs.enumerated() {
        next[id] = PagePlacement(frame: frames.panes[index], cropOnly: false,
                                 roundedEdge: roundedEdge(at: index, count: split.tabIDs.count))
      }
    } else if let selectedTabID, pages[selectedTabID] != nil {
      next[selectedTabID] = PagePlacement(frame: bounds, cropOnly: false)
    }
    updatePresentationLayout(next, animated: animatedPresentation, animatedVisibility: animatedVisibility)
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

  /// One clock and one placement map drive both the content crop and toolbar.
  /// Only entering/leaving page controls change visibility; surviving controls
  /// keep their native state and animate position with their outer container.
  private func updatePresentationLayout(_ next: [UUID: PagePlacement], animated: Bool, animatedVisibility: Bool) {
    guard next != targets else {
      if presentationAnimationTimer == nil { applyPlacements(next) }
      return
    }
    let previousToolbarFrames = appearingToolbarFrames
    targets = next
    presentationAnimationTimer?.invalidate()
    presentationAnimationTimer = nil
    appearingToolbarFrames = [:]
    guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      applyPlacements(next, animatedVisibility: animatedVisibility && window != nil)
      return
    }
    let start = placements
    for (id, target) in next where target.toolbarVisible {
      if pages[id]?.toolbar?.arePageControlsVisible != true {
        appearingToolbarFrames[id] = target.frame
      } else if let previousFrame = previousToolbarFrames[id] {
        // An interrupted cancellation retains the chrome's actual placement;
        // it must not jump back to the still-expanding content crop.
        appearingToolbarFrames[id] = previousFrame
      }
    }
    let toolbarStarts = appearingToolbarFrames
    applyPlacements(interpolatedPlacements(from: start, to: next, amount: 0), animatedVisibility: animatedVisibility)
    let startTime = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let progress = min(1, (ProcessInfo.processInfo.systemUptime - startTime) / 0.3)
        let amount = CGFloat(progress * progress * (3 - 2 * progress))
        for (id, initial) in toolbarStarts {
          if let target = next[id] {
            self.appearingToolbarFrames[id] = self.interpolatedFrame(from: initial, to: target.frame, amount: amount)
          }
        }
        self.applyPlacements(self.interpolatedPlacements(from: start, to: next, amount: amount))
        if progress == 1 {
          self.presentationAnimationTimer?.invalidate()
          self.presentationAnimationTimer = nil
          self.appearingToolbarFrames = [:]
        }
      }
    }
    presentationAnimationTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func interpolatedPlacements(from start: [UUID: PagePlacement],
                                     to end: [UUID: PagePlacement], amount: CGFloat) -> [UUID: PagePlacement] {
    end.reduce(into: [:]) { result, entry in
      let (id, target) = entry
      guard amount < 1, let initial = start[id], initial.frame != target.frame else {
        result[id] = target
        return
      }
      let frame = interpolatedFrame(from: initial.frame, to: target.frame, amount: amount)
      // While exiting a split, keep the moving inner edge rounded until it
      // reaches Main View's outside boundary, where the outer clip takes over.
      result[id] = PagePlacement(frame: frame, cropOnly: true, toolbarVisible: target.toolbarVisible,
        roundedEdge: target.roundedEdge == .none ? initial.roundedEdge : target.roundedEdge)
    }
  }

  private func interpolatedFrame(from a: CGRect, to b: CGRect, amount: CGFloat) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * amount,
           y: a.minY + (b.minY - a.minY) * amount,
           width: a.width + (b.width - a.width) * amount,
           height: a.height + (b.height - a.height) * amount)
  }

  private func applyPlacements(_ next: [UUID: PagePlacement], animatedVisibility: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for (id, page) in pages {
      guard let placement = next[id] else {
        page.hide(animated: animatedVisibility)
        continue
      }
      applyCornerClipping(to: page.viewport, roundedEdge: placement.roundedEdge)
      page.layout(in: self, chromeHost: chromeOverlayHost, frame: placement.frame,
                  cropOnly: placement.cropOnly, toolbarVisible: placement.toolbarVisible && !isCovered,
                  toolbarLayoutFrame: appearingToolbarFrames[id] ?? placement.frame,
                  animatedVisibility: animatedVisibility)
      page.splitControl.place(in: self,
        chromeHost: (chromeOverlayHost as? BrowserToolbarLayoutHosting)?.splitPaneOverlayHost,
        paneFrame: placement.frame,
        addressFrame: page.toolbar?.addressCapsuleFrame(in: self),
        visible: split?.contains(id) == true && liftedPaneID == nil && previewTarget == nil && !isCovered
          && workspace?.isSpotlightPresented != true)
    }
    placements = next
  }

  /// Main View owns the shell's outside corners. This splitter host owns only
  /// the two corners on each pane's divider-facing edge, including previews.
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
    preview.material = .hudWindow
    preview.blendingMode = .withinWindow
    preview.state = .active
    preview.wantsLayer = true
    preview.layer?.cornerCurve = .continuous
    preview.layer?.masksToBounds = true
    preview.layer?.borderWidth = 1.5
    preview.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
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
    presentationAnimationTimer?.invalidate()
    if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
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
