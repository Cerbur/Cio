//
//  SidebarTabDrag.swift
//  NativeBrowser
//
//  Tab dragging inside the sidebar. A system drag session can only show a
//  static, translucent snapshot, so the dragged tab is drawn here instead: a
//  live Liquid Glass block that refracts the sidebar beneath it while it
//  follows the pointer. The tier under the pointer opens a gap where the tab
//  would land, and the block settles into that gap when it is dropped.
//

import SwiftUI

/// The sidebar-wide coordinate space shared by drag geometry and the overlay.
enum SidebarTabDragSpace {
  static let name = "cio.sidebar.tab-drag"
  static let splitReveal = "cio.sidebar.split-reveal"
}

/// A dragged tab lands before `before`, or at the end of `tier` when it is nil.
struct SidebarTabDropTarget: Equatable {
  var tier: WorkspaceCollection.TabTier
  var before: UUID?
}

/// The selected Space's tier orders, read each time the pointer moves.
struct SidebarTabDragLayout {
  var spaceID: UUID
  var globalTabIDs: [UUID]
  var globalPinnedTabCount: Int
  var groupedTabIDs: Set<UUID>
  var groupSizes: [UUID: Int] = [:]
  var spacePinTabIDs: [UUID]
  var temporaryTabIDs: [UUID]
  var tileSize: CGSize
  var topInset: CGFloat

  func tabIDs(in tier: WorkspaceCollection.TabTier) -> [UUID] {
    switch tier {
    case .global: return globalTabIDs
    case .space: return spacePinTabIDs
    case .temporary: return temporaryTabIDs
    }
  }
}

@MainActor
@Observable
final class SidebarTabDrag {
  enum Style: Equatable {
    case row
    case tile
    case card

    init(_ tier: WorkspaceCollection.TabTier) {
      self = tier == .global ? .tile : .row
    }
  }

  enum Phase: Equatable {
    /// The tab has left its tier and follows the pointer.
    case lifted
    /// The block is settling into its new slot or returning to its old one.
    case landing
  }

  private(set) var isPaneDrag = false
  private(set) var paneGlassOpacity: Double = 1
  private(set) var isMinimizingPane = false
  @ObservationIgnored private var paneLandingFrame: CGRect?
  @ObservationIgnored private var paneCollapseCommit: (() -> Bool)?
  @ObservationIgnored private var paneCollapseFlightFinished = false
  private(set) var isExpandingIntoSplit = false
  private(set) var splitLandingTabIDs: [UUID]?
  @ObservationIgnored private var presentedFloatingFrame: CGRect?
  @ObservationIgnored var layoutProvider: (() -> SidebarTabDragLayout?)?
  @ObservationIgnored private var paneSourceFrame = CGRect.zero
  @ObservationIgnored private var paneSourceTabIDs = Set<UUID>()
  private(set) var tabID: UUID?
  private(set) var phase = Phase.lifted
  private(set) var isLifted = false
  /// Captured at lift so the Tab can preserve its initial material treatment.
  private(set) var startedFromStableTab = false
  /// Where the lifted tab would land; that tier shows a gap there.
  private(set) var target: SidebarTabDropTarget?
  private(set) var style = Style.row
  private(set) var size = CGSize.zero
  /// The pointer's position; the block keeps `grab` under it.
  private(set) var anchor = CGPoint.zero
  /// Where the pointer took hold of the tab, as a fraction of its size.
  private(set) var grab = CGPoint(x: 0.5, y: 0.5)
  private(set) var autoscrollDirection = 0

  /// The tab that is out of its tier while it follows the pointer.
  var liftedTabID: UUID? { phase == .lifted ? tabID : nil }
  var sidebarLiftedTabID: UUID? { isPaneDrag ? nil : liftedTabID }
  var isDragging: Bool { liftedTabID != nil }

  @ObservationIgnored var externalBounds: (() -> CGRect)?
  @ObservationIgnored var onPointerMove: ((UUID, CGPoint) -> Void)?
  @ObservationIgnored var onSplitDrop: ((UUID) -> Bool)?
  /// Committed pane geometry in the same coordinates as the floating block.
  @ObservationIgnored var onSplitLandingFrame: (() -> CGRect?)?
  @ObservationIgnored var onSplitRevealFrame: ((CGRect?) -> Void)?
  @ObservationIgnored var onPreviewEnd: (() -> Void)?
  @ObservationIgnored var onPaneCollapseFrame: ((UUID, CGRect) -> Void)?
  @ObservationIgnored var onPaneCollapseBegin: ((UUID, CGRect) -> Void)?
  @ObservationIgnored var onPaneCollapseEnd: ((UUID) -> Void)?
  @ObservationIgnored var isStableTab: ((UUID) -> Bool)?
  @ObservationIgnored var bounds = CGRect.zero
  @ObservationIgnored var topPinFrame = CGRect.zero
  @ObservationIgnored var spaceFrame = CGRect.zero
  @ObservationIgnored var spaceHeaderFrame = CGRect.zero
  @ObservationIgnored var reduceMotion = false
  @ObservationIgnored private(set) var autoscrollSpeed: CGFloat = 0

  /// A tab can briefly have two views while it moves between tiers: the old
  /// one leaving and the new one arriving. Each is tracked on its own.
  private struct ItemKey: Hashable {
    var id: UUID
    var tier: WorkspaceCollection.TabTier
  }

  private struct Item {
    var frame: CGRect
    var token: UUID
    var closeWidth: CGFloat
  }

  @ObservationIgnored private var items: [ItemKey: Item] = [:]
  @ObservationIgnored private var panelRows: [SpaceTabPanelRow.ID: (row: SpaceTabPanelRow, frame: CGRect, token: UUID)] = [:]
  @ObservationIgnored private var tierFrames: [WorkspaceCollection.TabTier: CGRect] = [:]
  @ObservationIgnored private var rowSize: CGSize?
  @ObservationIgnored private var layout: SidebarTabDragLayout?
  @ObservationIgnored private var pointer = CGPoint.zero
  @ObservationIgnored private var sourceTier = WorkspaceCollection.TabTier.global
  @ObservationIgnored private var sourceSize = CGSize.zero
  @ObservationIgnored private var isOutsideSidebar = false
  @ObservationIgnored private var isOverTopPins = false
  /// Dropping here leaves the tab where it was.
  @ObservationIgnored private var homeTarget: SidebarTabDropTarget?
  @ObservationIgnored private var landingTier: WorkspaceCollection.TabTier?
  @ObservationIgnored private var landingFlight = 0
  @ObservationIgnored private var programmaticLandingPending = false
  @ObservationIgnored private var ignoresGesture = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var lastDrop: (tabID: UUID, time: TimeInterval)?

  // MARK: - Geometry

  // PROBE-BEGIN (temporary)
  static weak var probeInstance: SidebarTabDrag?
  func probeFrame(of id: UUID) -> CGRect? { items.first { $0.key.id == id }?.value.frame }
  var probeBounds: CGRect { bounds }
  var probeTopPinFrame: CGRect { topPinFrame }
  func probeTierFrame(_ tier: WorkspaceCollection.TabTier) -> CGRect? { tierFrames[tier] }
  // PROBE-END

  func register(_ id: UUID, in tier: WorkspaceCollection.TabTier, frame: CGRect, token: UUID, isCompact: Bool = false) {
    Self.probeInstance = self // PROBE-LINE
    items[ItemKey(id: id, tier: tier)] = Item(frame: frame, token: token, closeWidth: isCompact ? 18 : 32)
    if tier != .global && !isCompact { rowSize = frame.size }
    // Frames arrive while the tier is still animating; each one re-aims the
    // landing so the block meets the slot where it comes to rest.
    if id == tabID, phase == .landing, tier == landingTier, !programmaticLandingPending {
      land(in: frame, style: Style(tier))
    }
  }

  func unregister(_ id: UUID, in tier: WorkspaceCollection.TabTier, token: UUID) {
    let key = ItemKey(id: id, tier: tier)
    if items[key]?.token == token { items[key] = nil }
  }

  /// Rows supply geometry and membership as a unit. A row that changes tier
  /// retains its identity, so discard its old registration before reattaching.
  func register(_ row: SpaceTabPanelRow, frame: CGRect, token: UUID) {
    if let previous = panelRows[row.id], previous.row.tier != row.tier,
       let id = previous.row.draggableTabID, let tier = previous.row.tier {
      unregister(id, in: tier, token: previous.token)
    }
    panelRows[row.id] = (row, frame, token)
    if let id = row.draggableTabID, let tier = row.tier {
      register(id, in: tier, frame: frame, token: token)
    }
    switch row.id {
    case .divider(let spaceID), .newTab(let spaceID), .footer(let spaceID):
      updatePanelTierFrames(in: spaceID)
    default: break
    }
  }

  func unregister(_ row: SpaceTabPanelRow, token: UUID) {
    guard let previous = panelRows[row.id], previous.token == token else { return }
    if let id = previous.row.draggableTabID, let tier = previous.row.tier {
      unregister(id, in: tier, token: token)
    }
    panelRows[row.id] = nil
  }

  private func updatePanelTierFrames(in spaceID: UUID) {
    if let divider = panelRows[.divider(spaceID)]?.frame {
      let top = spaceHeaderFrame.maxY
      // The divider's upper half remains a pin drop target even with no
      // visible pins. An empty tier needs no extra blank row in the panel.
      let bottom = max(top, divider.midY)
      tierFrames[.space(spaceID)] = CGRect(x: divider.minX, y: top, width: divider.width, height: bottom - top)
    }
    if let newTab = panelRows[.newTab(spaceID)]?.frame, let footer = panelRows[.footer(spaceID)]?.frame {
      let top = newTab.maxY + BrowserLayout.sidebarRowSpacing
      tierFrames[.temporary(spaceID)] = CGRect(x: newTab.minX, y: top, width: newTab.width,
                                              height: max(0, footer.maxY - top))
    }
  }

  /// A space tab tier's list. The bottom of space pin's list divides its
  /// targets from temporary's.
  func register(_ tier: WorkspaceCollection.TabTier, frame: CGRect) {
    tierFrames[tier] = frame
  }

  private func frame(of id: UUID, in tier: WorkspaceCollection.TabTier) -> CGRect? {
    items[ItemKey(id: id, tier: tier)]?.frame
  }

  /// Only tab selection targets may receive clicks through Spotlight's shell overlay.
  func tabSelection(at point: CGPoint, in selectedSpaceID: UUID) -> UUID? {
    if topPinFrame.contains(point),
       let item = items.first(where: { key, item in
         key.tier == .global && item.frame.contains(point)
       }) {
      return item.key.id
    }
    guard visibleSpaceFrame.contains(point) else { return nil }
    return items.first(where: { key, item in
      (key.tier == .space(selectedSpaceID) || key.tier == .temporary(selectedSpaceID))
        && item.frame.contains(point)
        // The trailing close control is not part of the tab selection button.
        && point.x < item.frame.maxX - item.closeWidth
    })?.key.id
  }

  /// The landing tab stays hidden until the glass block reaches it.
  func sourceOpacity(of id: UUID) -> Double {
    if isMinimizingPane, paneCollapseCommit != nil { return 1 }
    return isPaneDrag && phase == .lifted ? 1 : (tabID == id ? 0 : 1)
  }

  /// SwiftUI still completes the click on the button a drag started from when
  /// the mouse is released over it, so that click is ignored.
  func suppressesClick(on id: UUID) -> Bool {
    if tabID == id { return true }
    guard let lastDrop, lastDrop.tabID == id else { return false }
    return ProcessInfo.processInfo.systemUptime - lastDrop.time < 0.3
  }

  // MARK: - Gesture

  func pointerMoved(from start: CGPoint, to location: CGPoint, layout: SidebarTabDragLayout) {
    guard !ignoresGesture else { return }
    self.layout = layout
    pointer = location
    if !isDragging, !begin(at: start, in: layout) {
      ignoresGesture = true
      return
    }
    resolveTarget()
    anchor = clampedAnchor(pointer)
    updateAutoscroll()
    if let tabID { onPointerMove?(tabID, location) }
  }

  /// A pane starts at its page frame, then contracts into the same glass card
  /// used by sidebar tabs. The durable group is untouched until a valid drop.
  func beginPane(_ id: UUID, tier: WorkspaceCollection.TabTier, at point: CGPoint, frame: CGRect,
                 groupTabIDs: [UUID]) -> Bool {
    guard !isDragging, let layout = layoutProvider?() else { return false }
    finish(animated: false)
    generation += 1
    self.layout = layout
    isPaneDrag = true
    paneSourceFrame = frame
    paneSourceTabIDs = Set(groupTabIDs)
    paneGlassOpacity = 0
    startedFromStableTab = true
    sourceTier = tier
    sourceSize = frame.size
    homeTarget = nil
    target = nil
    phase = .lifted
    style = .card
    size = frame.size
    grab = CGPoint(x: min(max((point.x - frame.minX) / max(frame.width, 1), 0), 1),
                   y: min(max((point.y - frame.minY) / max(frame.height, 1), 0), 1))
    anchor = CGPoint(x: frame.minX + grab.x * frame.width, y: frame.minY + grab.y * frame.height)
    pointer = point
    isOutsideSidebar = true
    tabID = id
    let generation = generation
    // The native handle tracks in eventTracking mode. Keep the initial morph
    // running during that loop, and respect any region entered in the meantime.
    let liftTimer = Timer(timeInterval: 0.016, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.generation == generation, self.isPaneDrag, self.isDragging else { return }
        withAnimation(self.reduceMotion ? nil : BrowserSplitRevealTransition.Direction.exit.animation) {
          self.size = self.blockSize(for: self.style)
          self.paneGlassOpacity = 1
          self.isLifted = true
        }
      }
    }
    RunLoop.main.add(liftTimer, forMode: .common)
    return true
  }

  var paneLiftTargetFrame: CGRect {
    let card = BrowserSplitRevealTransition.cardSize
    return CGRect(x: anchor.x - grab.x * card.width, y: anchor.y - grab.y * card.height,
                  width: card.width, height: card.height)
  }

  /// Keep the split intact while its pane contracts. Detachment and survivor
  /// expansion start at the native animation's midpoint, before row landing.
  func minimizePane(_ id: UUID, tier: WorkspaceCollection.TabTier, frame: CGRect,
                    commit: @escaping () -> Bool) -> Bool {
    guard tabID == nil, !reduceMotion, let begin = onPaneCollapseBegin,
          let landing = projectedPaneLandingFrame(id, in: tier) else { return false }
    generation += 1
    isPaneDrag = true
    isMinimizingPane = true
    paneSourceFrame = frame
    sourceTier = tier
    sourceSize = frame.size
    size = frame.size
    style = .card
    grab = CGPoint(x: 0.5, y: 0.5)
    anchor = CGPoint(x: frame.midX, y: frame.midY)
    paneGlassOpacity = 0
    startedFromStableTab = true
    isLifted = false
    phase = .landing
    tabID = id
    landingTier = tier
    programmaticLandingPending = true
    paneCollapseCommit = commit
    paneCollapseFlightFinished = false
    begin(id, landing)
    return true
  }

  /// Detachment inserts a tab immediately after the surviving split row.
  /// Both containers use the shared row height, so its landing is known before
  /// changing workspace membership. Independent rows and Top Pins stay put.
  private func projectedPaneLandingFrame(_ id: UUID, in tier: WorkspaceCollection.TabTier) -> CGRect? {
    if let group = panelRows.values.first(where: {
      $0.row.tier == tier && $0.row.splitGroup?.contains(id) == true
    }) {
      return group.frame.offsetBy(dx: 0, dy: BrowserLayout.sidebarTabRowHeight + BrowserLayout.sidebarRowSpacing)
    }
    return frame(of: id, in: tier)
  }

  func commitPaneCollapse(_ id: UUID) {
    guard isMinimizingPane, tabID == id, let commit = paneCollapseCommit else { return }
    paneCollapseCommit = nil
    let tier = sourceTier
    // The group leader's old registration describes the whole split row.
    // Wait for the newly detached tab's own row before capturing its landing.
    if panelRows.values.contains(where: {
      $0.row.tier == tier && $0.row.draggableTabID == id && $0.row.splitGroup != nil
    }) {
      items[ItemKey(id: id, tier: tier)] = nil
    }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    var committed = false
    withTransaction(transaction) { committed = commit() }
    guard committed else { finish(animated: false); return }
    programmaticLandingPending = false
    if let frame = frame(of: id, in: tier) {
      land(in: frame, style: Style(tier))
    } else {
      // New rows report their frame via register; no timed pause between halves.
      settle(id, in: tier)
    }
  }

  func movePane(to point: CGPoint) {
    guard isPaneDrag, isDragging, let id = tabID else { return }
    if let layout = layoutProvider?() { self.layout = layout }
    pointer = point
    resolveTarget()
    anchor = clampedAnchor(point)
    updateAutoscroll()
    onPointerMove?(id, point)
  }

  func drop(_ move: (UUID, SidebarTabDropTarget) -> Bool) {
    defer { ignoresGesture = false }
    guard !ignoresGesture, isDragging, let id = tabID else { return }
    if onSplitDrop?(id) == true {
      lastDrop = (id, ProcessInfo.processInfo.systemUptime)
      onPreviewEnd?()
      if onSplitLandingFrame?() != nil, !reduceMotion {
        expandIntoSplit()
      } else {
        finish(animated: false)
      }
      return
    }
    // A pane is already absent from the preview. Commit its sidebar move
    // before clearing that preview, or it briefly expands back into the split.
    if !isPaneDrag { onPreviewEnd?() }
    let target = target
    setAutoscroll(0)
    lastDrop = (id, ProcessInfo.processInfo.systemUptime)
    if let target, target != homeTarget, move(id, target) {
      phase = .landing
      if isPaneDrag { onPreviewEnd?() }
      settle(id, in: target.tier)
    } else {
      if isPaneDrag { onPreviewEnd?() }
      returnToSource(id)
    }
  }

  /// A cancelled gesture never reaches `drop`.
  func gestureDidEnd() {
    onPreviewEnd?()
    if isDragging, let id = tabID {
      setAutoscroll(0)
      returnToSource(id)
    }
    ignoresGesture = false
  }

  /// Re-resolves the drop target after the list scrolled beneath the pointer.
  func listDidScroll() {
    guard isDragging else { return }
    resolveTarget()
  }

  private func begin(at start: CGPoint, in layout: SidebarTabDragLayout) -> Bool {
    let visibleSpace = visibleSpaceFrame
    guard let (key, item) = items.first(where: { key, item in
      item.frame.contains(start)
        && (key.tier == .global ? topPinFrame : visibleSpace).contains(start)
        && layout.tabIDs(in: key.tier).contains(key.id)
    }) else { return false }

    finish(animated: false)
    generation += 1
    let id = key.id
    startedFromStableTab = isStableTab?(id) ?? false
    let tierIDs = layout.tabIDs(in: key.tier)
    let next = tierIDs.firstIndex(of: id).flatMap { index in
      index + 1 < tierIDs.count ? tierIDs[index + 1] : nil
    }
    homeTarget = SidebarTabDropTarget(tier: key.tier, before: next)
    sourceTier = key.tier
    sourceSize = item.frame.size
    isOutsideSidebar = false
    isOverTopPins = key.tier == .global
    style = Style(key.tier)
    size = item.frame.size
    grab = CGPoint(
      x: (start.x - item.frame.minX) / max(item.frame.width, 1),
      y: (start.y - item.frame.minY) / max(item.frame.height, 1))
    anchor = start
    // The tab's slot becomes a gap in the same place, under the new block.
    target = homeTarget
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
      tabID = id
    }
    // Rise on the next frame so the block visibly lifts out of its slot.
    let generation = generation
    Task { @MainActor [weak self] in
      guard let self, self.generation == generation, self.isDragging else { return }
      withAnimation(self.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.68)) {
        self.isLifted = true
      }
    }
    return true
  }

  // MARK: - Landing

  func prepareSplitLanding(tabIDs: [UUID]) {
    splitLandingTabIDs = tabIDs
  }

  /// Hand the floating glass over to the native page viewport. That common
  /// parent owns the expansion; this model only retains drag/drop lifetime.
  private func expandIntoSplit() {
    let source = presentedFloatingFrame ?? CGRect(
      x: anchor.x - grab.x * size.width, y: anchor.y - grab.y * size.height,
      width: size.width, height: size.height)
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { isExpandingIntoSplit = true }
    onSplitRevealFrame?(source)
    phase = .landing
    landingTier = nil
    programmaticLandingPending = true
    setAutoscroll(0)
    landingFlight += 1
    let flight = landingFlight
    let generation = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + BrowserSplitRevealTransition.duration) { [weak self] in
      guard let self, self.generation == generation, self.landingFlight == flight else { return }
      self.finish(animated: false)
    }
  }

  func splitRevealFrameDidChange(_ frame: CGRect) {
    // Capture actual presentation geometry, including a still-running drag
    // morph. Native page animations start here rather than at the model target.
    if !isExpandingIntoSplit {
      // The outer layout box is centered at the pointer; its content applies
      // the fractional-grab offset internally. Include that visible offset.
      presentedFloatingFrame = frame.offsetBy(dx: (0.5 - grab.x) * frame.width,
                                            dy: (0.5 - grab.y) * frame.height)
    }
  }

  /// Menu and keyboard moves use the same floating block and landing spring
  /// as a pointer drop, starting at the tab's existing sidebar frame.
  func animateMove(_ id: UUID, from source: WorkspaceCollection.TabTier,
                   to target: SidebarTabDropTarget,
                   move: @escaping (UUID, SidebarTabDropTarget) -> Bool) {
    guard !isDragging else { return }
    finish(animated: false)
    guard !reduceMotion, let frame = frame(of: id, in: source),
          frame.intersects(visibleSpaceFrame) else {
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { _ = move(id, target) }
      return
    }
    generation += 1
    let generation = generation
    startedFromStableTab = isStableTab?(id) ?? false
    sourceTier = source
    sourceSize = frame.size
    size = frame.size
    style = Style(source)
    grab = CGPoint(x: 0.5, y: 0.5)
    anchor = CGPoint(x: frame.midX, y: frame.midY)
    phase = .landing
    tabID = id
    isLifted = true
    programmaticLandingPending = true
    // Commit immediately so repeated shortcuts always toggle the latest tier.
    // Keep the overlay at its origin for its first frame before aiming it at
    // the destination reported by the updated list.
    var moved = false
    withAnimation(.smooth(duration: 0.28)) { moved = move(id, target) }
    landingTier = moved ? target.tier : source
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(16))
      guard let self, self.generation == generation, self.tabID == id else { return }
      self.programmaticLandingPending = false
      if let frame = self.frame(of: id, in: moved ? target.tier : source) {
        self.land(in: frame, style: Style(moved ? target.tier : source))
      } else {
        self.settle(id, in: moved ? target.tier : source)
      }
    }
  }

  /// Waits for the tab's view in `tier` to report its new frame.
  private func settle(_ id: UUID, in tier: WorkspaceCollection.TabTier) {
    landingTier = tier
    let generation = generation
    let flight = landingFlight
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, self.generation == generation, self.landingFlight == flight else { return }
      // The tab kept its frame, or it now sits outside the visible list.
      if let frame = self.frame(of: id, in: tier) {
        self.land(in: frame, style: Style(tier))
      } else {
        self.finish(animated: true)
      }
    }
  }

  private func returnToSource(_ id: UUID) {
    // The tier closes the gap it opened and makes room at the tab's slot again.
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
      phase = .landing
    }
    if isPaneDrag, onSplitLandingFrame?() != nil, !reduceMotion {
      // Cancellation hands the floating glass back to the live page animator,
      // just like a successful split drop; no separate snapshot landing spring.
      expandIntoSplit()
    } else if isPaneDrag {
      land(in: paneSourceFrame, style: .card)
    } else {
      settle(id, in: sourceTier)
    }
  }

  private func land(in frame: CGRect, style: Style) {
    if isMinimizingPane {
      // Registration can report the same row repeatedly during layout. Its
      // committed destination is captured once; never restart a moving flight.
      guard paneLandingFrame == nil, let id = tabID else { return }
      paneLandingFrame = frame
      landingFlight += 1
      onPaneCollapseFrame?(id, frame)
      if paneCollapseFlightFinished { finish(animated: false) }
      return
    }
    guard !reduceMotion else {
      finish(animated: true)
      return
    }
    landingFlight += 1
    let flight = landingFlight
    let generation = generation
    withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
      self.style = style
      size = frame.size
      anchor = CGPoint(
        x: frame.minX + grab.x * frame.width,
        y: frame.minY + grab.y * frame.height)
      isLifted = false
    } completion: { [weak self] in
      guard let self, self.generation == generation, self.landingFlight == flight else { return }
      self.finish(animated: true)
    }
  }

  func paneCollapseDidFinish(_ id: UUID) {
    guard isMinimizingPane, tabID == id else { return }
    paneCollapseFlightFinished = true
    if paneLandingFrame != nil { finish(animated: false) }
  }

  func cancelPaneCollapse(_ id: UUID) {
    guard isMinimizingPane, tabID == id else { return }
    finish(animated: false)
  }

  private func finish(animated: Bool) {
    guard tabID != nil else { return }
    if isMinimizingPane, let id = tabID { onPaneCollapseEnd?(id) }
    if isExpandingIntoSplit { onSplitRevealFrame?(nil) }
    onPreviewEnd?()
    landingTier = nil
    paneCollapseCommit = nil
    paneCollapseFlightFinished = false
    programmaticLandingPending = false
    landingFlight += 1
    setAutoscroll(0)
    let animateHandoff = animated && !reduceMotion
    var transaction = Transaction(animation: animateHandoff ? .easeOut(duration: 0.18) : nil)
    transaction.disablesAnimations = !animateHandoff
    withTransaction(transaction) {
      tabID = nil
      isPaneDrag = false
      paneSourceTabIDs = []
      paneGlassOpacity = 1
      isMinimizingPane = false
      paneLandingFrame = nil
      isExpandingIntoSplit = false
      splitLandingTabIDs = nil
      presentedFloatingFrame = nil
      target = nil
      phase = .lifted
      isLifted = false
    }
  }

  // MARK: - Targeting

  private var visibleSpaceFrame: CGRect {
    // Scrolling tabs beneath the fixed Space block cannot be selected or lifted.
    let top = max(spaceFrame.minY, spaceHeaderFrame.maxY)
    return CGRect(
      x: spaceFrame.minX, y: top,
      width: spaceFrame.width, height: max(0, spaceFrame.maxY - top))
  }

  /// Targets are read from the tiers as drawn, gap included. Moving the gap
  /// past a tab moves that tab by the gap's size, so the pointer stays in the
  /// gap and the target cannot flicker between two slots.
  private func resolveTarget() {
    guard let id = tabID, let layout else { return }
    // Separate exit and entry thresholds keep the card stable at the edge.
    let boundarySlop: CGFloat = 8
    if isOutsideSidebar {
      if pointer.x >= bounds.minX + boundarySlop,
         pointer.x <= bounds.maxX - boundarySlop {
        isOutsideSidebar = false
      }
    } else if pointer.x < bounds.minX - boundarySlop || pointer.x > bounds.maxX + boundarySlop {
      isOutsideSidebar = true
    }
    // Keep the tile/row morph stable when the top-pin gap changes geometry.
    if !isOutsideSidebar {
      if isOverTopPins {
        if pointer.y > topPinFrame.maxY + boundarySlop { isOverTopPins = false }
      } else if pointer.y < topPinFrame.maxY - boundarySlop {
        isOverTopPins = true
      }
    }
    let resolved: SidebarTabDropTarget?
    // Leaving the sidebar sideways puts the tab back where it started.
    if isOutsideSidebar {
      resolved = nil
    } else if isOverTopPins {
      resolved = topPinTarget(for: id, in: layout)
    } else {
      resolved = spaceTarget(for: id, in: layout)
    }
    if resolved != target {
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) { target = resolved }
    }

    // Presentation follows the region even when that tier cannot accept a drop.
    let nextStyle: Style = isOutsideSidebar ? .card : (isOverTopPins ? .tile : .row)
    guard nextStyle != style else { return }
    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78)) {
      style = nextStyle
      size = blockSize(for: nextStyle)
    }
  }

  private func blockSize(for style: Style) -> CGSize {
    if !isPaneDrag, style == Style(sourceTier) { return sourceSize }
    switch style {
    case .row: return rowSize ?? CGSize(width: max(bounds.width - 20, 1), height: BrowserLayout.sidebarTabRowHeight)
    case .tile: return layout?.tileSize ?? CGSize(width: 82, height: 40.5)
    case .card: return BrowserSplitRevealTransition.cardSize
    }
  }

  private func topPinTarget(for id: UUID, in layout: SidebarTabDragLayout) -> SidebarTabDropTarget? {
    let ids = layout.globalTabIDs
    let requiredPins = isPaneDrag ? 1 : (layout.groupSizes[id] ?? 1)
    guard (isPaneDrag && sourceTier == .global) || ids.contains(id)
      || layout.globalPinnedTabCount + requiredPins <= WorkspaceCollection.globalPinnedTabLimit else {
      return nil
    }
    let tiles = ids.filter { $0 != id && !paneSourceTabIDs.contains($0) }.compactMap { tileID in
      frame(of: tileID, in: .global).map { (id: tileID, frame: $0) }
    }
    // Tiles read left to right, then top to bottom; half the grid spacing
    // separates one grid row from the next.
    let gap: CGFloat = 4.5
    let index = tiles.firstIndex { tile in
      pointer.y < tile.frame.maxY + gap
        && (pointer.y < tile.frame.minY - gap || pointer.x < tile.frame.midX)
    } ?? tiles.count
    return SidebarTabDropTarget(tier: .global, before: index < tiles.count ? tiles[index].id : nil)
  }

  private func spaceTarget(for id: UUID, in layout: SidebarTabDragLayout) -> SidebarTabDropTarget? {
    let visible = visibleSpaceFrame
    guard visible.height > 0 else { return nil }
    let y = min(max(pointer.y, visible.minY), visible.maxY)
    let pinTier = WorkspaceCollection.TabTier.space(layout.spaceID)
    let inPins = tierFrames[pinTier].map { y <= $0.maxY } ?? false
    let tier = inPins ? pinTier : .temporary(layout.spaceID)
    // The source group remains visible, but dropping onto one of its members
    // is rejected by the workspace. Reserve the next valid list boundary.
    let rows = layout.tabIDs(in: tier).filter { $0 != id && !paneSourceTabIDs.contains($0) }.compactMap { rowID in
      frame(of: rowID, in: tier).map { (id: rowID, frame: $0) }
    }
    let index = rows.firstIndex { y < $0.frame.midY } ?? rows.count
    return SidebarTabDropTarget(tier: tier, before: index < rows.count ? rows[index].id : nil)
  }

  private func clampedAnchor(_ point: CGPoint) -> CGPoint {
    // Clamp only the pointer. Size-dependent clamping would jump to the new
    // card's bounds before the glass has finished morphing to that size.
    let dragBounds = externalBounds?() ?? bounds
    let minX = dragBounds.minX
    let maxX = dragBounds.maxX
    let minY = max(dragBounds.minY, layout?.topInset ?? 0)
    let maxY = dragBounds.maxY
    return CGPoint(
      x: min(max(point.x, minX), max(minX, maxX)),
      y: min(max(point.y, minY), max(minY, maxY)))
  }

  // MARK: - Autoscroll

  private func updateAutoscroll() {
    let visible = visibleSpaceFrame
    let zone: CGFloat = 36
    var speed: CGFloat = 0
    if visible.height > zone * 2, pointer.x >= bounds.minX, pointer.x <= bounds.maxX {
      if pointer.y >= visible.minY, pointer.y < visible.minY + zone {
        speed = -(80 + 520 * (1 - (pointer.y - visible.minY) / zone))
      } else if pointer.y > visible.maxY - zone {
        speed = 80 + 520 * min(1, (pointer.y - (visible.maxY - zone)) / zone)
      }
    }
    setAutoscroll(speed)
  }

  private func setAutoscroll(_ speed: CGFloat) {
    autoscrollSpeed = speed
    let direction = speed < 0 ? -1 : (speed > 0 ? 1 : 0)
    if autoscrollDirection != direction { autoscrollDirection = direction }
  }
}

/// A virtual row/tile reserves the landing position without creating a tab or
/// changing the durable split group. Its surrounding stack supplies movement.
struct SidebarTabDropSlot: View {
  var body: some View {
    Color.clear
      .background(.primary.opacity(0.04), in: SidebarTabAppearance.glassShape)
      .overlay {
        SidebarTabAppearance.glassShape.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
      }
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }
}

extension View {
  /// Reports this view's frame in the sidebar drag coordinate space.
  func onSidebarFrameChange(_ action: @escaping (CGRect) -> Void) -> some View {
    onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(SidebarTabDragSpace.name))
    } action: { frame in
      action(frame)
    }
  }
}

/// Makes a top pin tile or tab row draggable and reports where it is.
struct SidebarTabDragItem: ViewModifier {
  let drag: SidebarTabDrag
  let tabID: UUID
  let tier: WorkspaceCollection.TabTier
  var isCompact = false
  @State private var token = UUID()
  @State private var lastFrame = LastFrame()

  /// A lazy stack can bring back a row it removed with its old state, and
  /// then its unchanged frame is not reported again; the row re-registers
  /// that frame when it reappears. Holding it here does not re-render the row.
  private final class LastFrame {
    var value: CGRect?
  }

  func body(content: Content) -> some View {
    content
      .opacity(drag.sourceOpacity(of: tabID))
      // Visibility is a container handoff; the Tab owns material transitions.
      .animation(nil, value: drag.sourceOpacity(of: tabID))
      .onSidebarFrameChange { frame in
        lastFrame.value = frame
        drag.register(tabID, in: tier, frame: frame, token: token, isCompact: isCompact)
      }
      .onAppear {
        if let frame = lastFrame.value { drag.register(tabID, in: tier, frame: frame, token: token, isCompact: isCompact) }
      }
      .onDisappear { drag.unregister(tabID, in: tier, token: token) }
  }
}

/// Scrolls a Space's tab list while a dragged tab rests near its top or bottom.
struct SidebarTabDragAutoscroll: ViewModifier {
  let drag: SidebarTabDrag
  let isActive: Bool
  @State private var position = ScrollPosition()
  @State private var metrics = Metrics()

  /// Scroll geometry is read by the autoscroll loop only; storing it must not
  /// re-render the list on every scrolled point.
  private final class Metrics {
    var geometry: ScrollGeometry?
  }

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
        metrics.geometry = geometry
      }
      .task(id: isActive ? drag.autoscrollDirection : 0) {
        guard isActive, drag.autoscrollDirection != 0 else { return }
        var last = ContinuousClock.now
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(16))
          let now = ContinuousClock.now
          let elapsed = CGFloat((now - last) / .seconds(1))
          last = now
          guard let geometry = metrics.geometry else { continue }
          let minY = -geometry.contentInsets.top
          let maxY = max(
            minY,
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
          let y = min(max(geometry.contentOffset.y + drag.autoscrollSpeed * elapsed, minY), maxY)
          guard abs(y - geometry.contentOffset.y) > 0.1 else { continue }
          position.scrollTo(y: y)
          drag.listDidScroll()
        }
      }
  }
}

/// The glass block that follows the pointer.
struct SidebarTabDragOverlay<Label: View>: View {
  let drag: SidebarTabDrag
  @ViewBuilder let label: (UUID, SidebarTabDrag.Style) -> Label
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var glassNamespace

  var body: some View {
    GlassEffectContainer {
      if let id = drag.tabID, !drag.isExpandingIntoSplit, !drag.isMinimizingPane {
        let presentation = SidebarTabPresentation(
          placement: drag.style == .card ? .splitPreview : (drag.style == .tile ? .topPin : .liftedRow),
          isDragged: true, isLifted: drag.isLifted,
          preservesGlassContinuity: drag.startedFromStableTab, grab: drag.grab)
        SidebarFloatingRowContainer(size: drag.size, grab: drag.grab) {
          label(id, drag.style)
            .modifier(SidebarTabSurface(usesScrollEdge: false))
            .glassEffectID(id, in: glassNamespace)
            .environment(\.sidebarTabPresentation, presentation)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(SidebarTabDragSpace.splitReveal))
        } action: { frame in
          drag.splitRevealFrameDidChange(frame)
        }
        .transition(presentation.transition)
        .opacity(drag.isPaneDrag ? drag.paneGlassOpacity : 1)
        // Pointer updates have no implicit animation. Only the model's explicit
        // morph/lift/landing transactions animate the block.
        .position(drag.anchor)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .coordinateSpace(name: SidebarTabDragSpace.splitReveal)
    .transaction { transaction in
      if reduceMotion {
        transaction.animation = nil
        transaction.disablesAnimations = true
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Detached row geometry. The Tab inside owns the glass/lift presentation.
private struct SidebarFloatingRowContainer<Content: View>: View, Animatable {
  nonisolated var size: CGSize
  let grab: CGPoint
  @ViewBuilder let content: Content

  nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(size.width, size.height) }
    set { size = CGSize(width: newValue.first, height: newValue.second) }
  }

  var body: some View {
    content
      // The material sees the interpolated frame, not an intrinsic-size switch.
      .frame(width: size.width, height: size.height)
      // Use the same interpolated size for the frame and fractional grab.
      .offset(x: (0.5 - grab.x) * size.width, y: (0.5 - grab.y) * size.height)
  }
}
