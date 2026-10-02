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
  private var previewSide: BrowserSplitLayout.Side?
  private var isCommittingSplitPreview = false
  private var resizingFraction: CGFloat?

  private struct PagePlacement: Equatable {
    var frame: CGRect
    var cropOnly: Bool
    var toolbarVisible: Bool = true
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
        guard self.bounds.contains(point), !self.divider.frame.contains(point) else { return event }
        self.workspace?.selectTab(id: point.x < self.divider.frame.minX ? split.leftTabID : split.rightTabID)
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
    self.selectedTabID = selectedTabID
    self.split = split
    // Identity follows live tabs, never pane count, selected section or split ID.
    // Every surface is mounted once in its viewport before CEF attaches to it.
    for (id, surface) in containers {
      if pages[id] == nil {
        let page = BrowserPagePresentation(tabID: id, surface: surface)
        pages[id] = page
        addSubview(page.viewport, positioned: .below, relativeTo: divider)
      }
      if let workspace, let history { pages[id]?.configureToolbar(workspace: workspace, history: history) }
      surface.setSurfaceVisible(split?.contains(id) ?? (id == selectedTabID))
    }
    for id in Array(pages.keys) where containers[id] == nil {
      guard let page = pages.removeValue(forKey: id) else { continue }
      page.hide(animated: window != nil)
      // Only runtime closure retires a page instance. Leave its native overlay
      // mounted until the common first-level component exit has completed.
      DispatchQueue.main.asyncAfter(deadline: .now() + ToolbarComponentAnimation.duration + 0.05) {
        page.dispose()
      }
    }
    applySurfaceLayout(animatedPresentation: isCommittingSplitPreview || pairChanged)
  }

  override func layout() {
    super.layout()
    applySurfaceLayout()
  }

  func previewSplit(on side: BrowserSplitLayout.Side?) {
    guard previewSide != side else { return }
    previewSide = side
    applySurfaceLayout(animatedPresentation: true)
  }

  /// Commit directly from the current preview placement. No full-width reset,
  /// no replacement toolbar, and no reparenting of the surviving Chromium view.
  func commitSplitPreview(_ commit: () -> Bool) -> Bool {
    let hadPreview = previewSide != nil
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
    var next: [UUID: PagePlacement] = [:]
    if let side = previewSide, let split {
      let frames = split.frames(in: bounds)
      let survivorID = side == .left ? split.rightTabID : split.leftTabID
      preview.frame = side == .left ? frames.left : frames.right
      divider.frame = frames.divider
      divider.isHidden = false
      for id in split.tabIDs {
        let survivor = id == survivorID
        next[id] = PagePlacement(frame: survivor ? (side == .left ? frames.right : frames.left)
          : collapsedFrame(for: id), cropOnly: true, toolbarVisible: survivor)
      }
    } else if let side = previewSide, let selectedTabID {
      let frames = BrowserSplitLayout.previewFrames(in: bounds, on: side,
        maximumSurvivorWidth: pages[selectedTabID]?.surface.frame.width ?? bounds.width)
      preview.frame = frames.target
      divider.isHidden = true
      next[selectedTabID] = PagePlacement(frame: frames.survivor, cropOnly: true)
    } else if let split {
      var shown = split
      shown.fraction = resizingFraction ?? split.fraction
      let frames = shown.frames(in: bounds)
      divider.frame = frames.divider
      divider.isHidden = false
      next[split.leftTabID] = PagePlacement(frame: frames.left, cropOnly: false)
      next[split.rightTabID] = PagePlacement(frame: frames.right, cropOnly: false)
    } else {
      divider.isHidden = true
      if let selectedTabID, pages[selectedTabID] != nil {
        next[selectedTabID] = PagePlacement(frame: bounds, cropOnly: false)
      }
    }
    updatePresentationLayout(next, animated: animatedPresentation)
  }

  private func collapsedFrame(for id: UUID) -> CGRect {
    let frame = placements[id]?.frame ?? pages[id]?.viewport.frame ?? .zero
    return CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0)
  }

  /// One clock and one placement map drive both the content crop and toolbar.
  /// Only entering/leaving page controls change visibility; surviving controls
  /// keep their native state and animate position with their outer container.
  private func updatePresentationLayout(_ next: [UUID: PagePlacement], animated: Bool) {
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
      applyPlacements(next, animatedVisibility: window != nil)
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
    applyPlacements(interpolatedPlacements(from: start, to: next, amount: 0), animatedVisibility: true)
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
      result[id] = PagePlacement(frame: frame, cropOnly: true, toolbarVisible: target.toolbarVisible)
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
      page.layout(in: self, chromeHost: chromeOverlayHost, frame: placement.frame,
                  cropOnly: placement.cropOnly, toolbarVisible: placement.toolbarVisible && !isCovered,
                  toolbarLayoutFrame: appearingToolbarFrames[id] ?? placement.frame,
                  animatedVisibility: animatedVisibility)
    }
    placements = next
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
      let fraction = BrowserSplitLayout.clampedFraction(
        x / max(1, self.bounds.width - BrowserSplitLayout.dividerWidth), width: self.bounds.width)
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
