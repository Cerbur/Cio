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

  private(set) var tabID: UUID?
  private(set) var phase = Phase.lifted
  private(set) var isLifted = false
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
  var isDragging: Bool { liftedTabID != nil }

  @ObservationIgnored var bounds = CGRect.zero
  @ObservationIgnored var topPinFrame = CGRect.zero
  @ObservationIgnored var spaceFrame = CGRect.zero
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
  }

  @ObservationIgnored private var items: [ItemKey: Item] = [:]
  @ObservationIgnored private var tierFrames: [WorkspaceCollection.TabTier: CGRect] = [:]
  @ObservationIgnored private var rowSize: CGSize?
  @ObservationIgnored private var layout: SidebarTabDragLayout?
  @ObservationIgnored private var pointer = CGPoint.zero
  @ObservationIgnored private var sourceTier = WorkspaceCollection.TabTier.global
  @ObservationIgnored private var sourceSize = CGSize.zero
  /// Dropping here leaves the tab where it was.
  @ObservationIgnored private var homeTarget: SidebarTabDropTarget?
  @ObservationIgnored private var landingTier: WorkspaceCollection.TabTier?
  @ObservationIgnored private var landingFlight = 0
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

  func register(_ id: UUID, in tier: WorkspaceCollection.TabTier, frame: CGRect, token: UUID) {
    Self.probeInstance = self // PROBE-LINE
    items[ItemKey(id: id, tier: tier)] = Item(frame: frame, token: token)
    if tier != .global { rowSize = frame.size }
    // Frames arrive while the tier is still animating; each one re-aims the
    // landing so the block meets the slot where it comes to rest.
    if id == tabID, phase == .landing, tier == landingTier { land(in: frame, style: Style(tier)) }
  }

  func unregister(_ id: UUID, in tier: WorkspaceCollection.TabTier, token: UUID) {
    let key = ItemKey(id: id, tier: tier)
    if items[key]?.token == token { items[key] = nil }
  }

  /// A space tab tier's list. The bottom of space pin's list divides its
  /// targets from temporary's.
  func register(_ tier: WorkspaceCollection.TabTier, frame: CGRect) {
    tierFrames[tier] = frame
  }

  private func frame(of id: UUID, in tier: WorkspaceCollection.TabTier) -> CGRect? {
    items[ItemKey(id: id, tier: tier)]?.frame
  }

  /// The landing tab stays hidden until the glass block reaches it.
  func sourceOpacity(of id: UUID) -> Double {
    tabID == id ? 0 : 1
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
  }

  func drop(_ move: (UUID, SidebarTabDropTarget) -> Bool) {
    defer { ignoresGesture = false }
    guard !ignoresGesture, isDragging, let id = tabID else { return }
    let target = target
    setAutoscroll(0)
    lastDrop = (id, ProcessInfo.processInfo.systemUptime)
    if let target, target != homeTarget, move(id, target) {
      phase = .landing
      settle(id, in: target.tier)
    } else {
      returnToSource(id)
    }
  }

  /// A cancelled gesture never reaches `drop`.
  func gestureDidEnd() {
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
    let tierIDs = layout.tabIDs(in: key.tier)
    let next = tierIDs.firstIndex(of: id).flatMap { index in
      index + 1 < tierIDs.count ? tierIDs[index + 1] : nil
    }
    homeTarget = SidebarTabDropTarget(tier: key.tier, before: next)
    sourceTier = key.tier
    sourceSize = item.frame.size
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
    settle(id, in: sourceTier)
  }

  private func land(in frame: CGRect, style: Style) {
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

  private func finish(animated: Bool) {
    guard tabID != nil else { return }
    landingTier = nil
    landingFlight += 1
    setAutoscroll(0)
    var transaction = Transaction(animation: animated ? .easeOut(duration: 0.18) : nil)
    transaction.disablesAnimations = !animated
    withTransaction(transaction) {
      tabID = nil
      target = nil
      phase = .lifted
      isLifted = false
    }
  }

  // MARK: - Targeting

  private var visibleSpaceFrame: CGRect {
    let top = max(spaceFrame.minY, topPinFrame.maxY)
    return CGRect(
      x: spaceFrame.minX, y: top,
      width: spaceFrame.width, height: max(0, spaceFrame.maxY - top))
  }

  /// Targets are read from the tiers as drawn, gap included. Moving the gap
  /// past a tab moves that tab by the gap's size, so the pointer stays in the
  /// gap and the target cannot flicker between two slots.
  private func resolveTarget() {
    guard let id = tabID, let layout else { return }
    let resolved: SidebarTabDropTarget?
    // Leaving the sidebar sideways puts the tab back where it started.
    if pointer.x < bounds.minX - 8 || pointer.x > bounds.maxX + 8 {
      resolved = nil
    } else if pointer.y < topPinFrame.maxY {
      resolved = topPinTarget(for: id, in: layout)
    } else {
      resolved = spaceTarget(for: id, in: layout)
    }
    if resolved != target {
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) { target = resolved }
    }

    // Over top pin the block takes a tile's shape; over a list, a row's.
    let nextStyle = Style(target?.tier ?? sourceTier)
    guard nextStyle != style else { return }
    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78)) {
      style = nextStyle
      size = blockSize(for: nextStyle)
    }
  }

  private func blockSize(for style: Style) -> CGSize {
    if style == Style(sourceTier) { return sourceSize }
    switch style {
    case .row: return rowSize ?? CGSize(width: max(bounds.width - 20, 1), height: 36)
    case .tile: return layout?.tileSize ?? CGSize(width: 82, height: 40.5)
    }
  }

  private func topPinTarget(for id: UUID, in layout: SidebarTabDragLayout) -> SidebarTabDropTarget? {
    let ids = layout.globalTabIDs
    guard ids.contains(id) || ids.count < WorkspaceCollection.globalPinnedTabLimit else {
      return nil
    }
    let tiles = ids.filter { $0 != id }.compactMap { tileID in
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
    let rows = layout.tabIDs(in: tier).filter { $0 != id }.compactMap { rowID in
      frame(of: rowID, in: tier).map { (id: rowID, frame: $0) }
    }
    let index = rows.firstIndex { y < $0.frame.midY } ?? rows.count
    return SidebarTabDropTarget(tier: tier, before: index < rows.count ? rows[index].id : nil)
  }

  private func clampedAnchor(_ point: CGPoint) -> CGPoint {
    // Leave room for the lifted block's scale.
    let margin = CGSize(width: 4 + size.width * 0.03, height: 2 + size.height * 0.03)
    let minX = bounds.minX + margin.width + grab.x * size.width
    let maxX = bounds.maxX - margin.width - (1 - grab.x) * size.width
    let minY = (layout?.topInset ?? 0) + margin.height + grab.y * size.height
    let maxY = bounds.maxY - margin.height - (1 - grab.y) * size.height
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
      .onSidebarFrameChange { frame in
        lastFrame.value = frame
        drag.register(tabID, in: tier, frame: frame, token: token)
      }
      .onAppear {
        if let frame = lastFrame.value { drag.register(tabID, in: tier, frame: frame, token: token) }
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

  var body: some View {
    GlassEffectContainer {
      if let id = drag.tabID {
        SidebarTabGlassBlock(style: drag.style, isLifted: drag.isLifted) {
          label(id, drag.style)
        }
        .frame(width: drag.size.width, height: drag.size.height)
        .offset(
          x: (0.5 - drag.grab.x) * drag.size.width,
          y: (0.5 - drag.grab.y) * drag.size.height)
        .glassEffectTransition(reduceMotion ? .identity : .materialize)
        .position(drag.anchor)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// A lifted tab: the same favicon and title on a free-floating glass block.
private struct SidebarTabGlassBlock<Content: View>: View {
  let style: SidebarTabDrag.Style
  let isLifted: Bool
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: style == .tile ? 18 : 12, style: .continuous)
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style == .tile ? .center : .leading)
      .glassEffect(.regular, in: shape)
      .scaleEffect(isLifted ? 1.04 : 1)
      .shadow(
        color: .black.opacity(isLifted ? 0.2 : 0.06),
        radius: isLifted ? 16 : 5,
        y: isLifted ? 9 : 2)
  }
}
