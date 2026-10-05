import AppKit

/// Window-coordinate events let the Main View bridge a pane to the sidebar's
/// existing glass drag without reparenting Chromium or committing on lift.
enum BrowserSplitPaneDragEvent {
  case begin(point: CGPoint, frame: CGRect, snapshot: NSImage?)
  case move(CGPoint)
  case end
  case cancel
}

/// Ordinary page-action buttons use colored SF Symbols for the traffic-light
/// appearance. Only the shell owns AppKit's window widgets and window menus.
@MainActor
final class BrowserSplitPaneControl: NSView {
  private let handle = SplitPaneHandleButton()
  private let capsule = NSGlassEffectView()
  private let actionContent = SplitPaneActionContentView()
  nonisolated(unsafe) private var dismissalMonitor: Any?
  private var expanded = false
  private var collapsedFrame = CGRect.zero
  private var expandedFrame = CGRect.zero
  var onDrag: ((BrowserSplitPaneDragEvent) -> Bool)?
  var onClose: (() -> Void)?
  var onMinimize: (() -> Void)?
  var onExpand: (() -> Void)?
  var dragSource: (() -> (CGRect, NSImage?))?
  /// Window geometry stays valid when the shell refreshes chrome independently
  /// of the page viewport (including initial sidebar-width restoration).
  var addressFrameProvider: (() -> CGRect?)?
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
          bounds.contains(convert(point, from: superview)) else { return nil }
    if expanded {
      // Glass hit-testing can pass through transparent regions. Resolve the
      // ordinary buttons directly and absorb the capsule's remaining area.
      return actionContent.actionButton(at: point, from: superview) ?? self
    }
    return handle
  }

  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}

  /// Address event monitors run before AppKit dispatches a mouse event. Honor
  /// the same top-layer hit before those monitors focus the covered editor.
  static func ownsHit(at windowPoint: NSPoint, in window: NSWindow) -> Bool {
    guard let root = window.contentView else { return false }
    let point = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
    var hit = root.hitTest(point)
    while let view = hit {
      if view is BrowserSplitPaneControl { return true }
      hit = view.superview
    }
    return false
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    handle.title = ""
    handle.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Split Page Actions")?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
    handle.imagePosition = .imageOnly
    handle.imageScaling = .scaleNone
    handle.isBordered = false
    handle.setButtonType(.momentaryChange)
    handle.toolTip = "Click for page actions; hold to move this page"
    handle.setAccessibilityLabel("Split Page Actions")
    handle.setAccessibilityIdentifier("split-pane-handle")
    handle.target = self
    handle.action = #selector(toggleCapsule)
    handle.onBegin = { [weak self] point in
      guard let self, let source = self.dragSource?() else { return false }
      self.collapse()
      return self.onDrag?(.begin(point: point, frame: source.0, snapshot: source.1)) ?? false
    }
    handle.onMove = { [weak self] point in _ = self?.onDrag?(.move(point)) }
    handle.onEnd = { [weak self] cancelled in _ = self?.onDrag?(cancelled ? .cancel : .end) }
    addSubview(handle)
    capsule.style = .regular
    capsule.cornerRadius = BrowserLayout.splitPaneCapsuleSize.height / 2
    let content = actionContent
    content.frame = CGRect(origin: .zero, size: BrowserLayout.splitPaneCapsuleSize)
    let actions: [(NSColor, String, String, Selector)] = [
      (.systemRed, "Close Split Page", "xmark.circle.fill", #selector(closePage)),
      (.systemYellow, "Move Split Page to Sidebar", "minus.circle.fill", #selector(minimizePage)),
      (.systemGreen, "Show Page Alone", "arrow.up.left.and.arrow.down.right.circle.fill", #selector(expandPage)),
    ]
    var buttons: [NSButton] = []
    for (index, item) in actions.enumerated() {
      let button = NSButton(frame: CGRect(origin: .zero,
        size: BrowserLayout.splitPaneActionSize))
      button.title = ""
      button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: item.1)?
        .withSymbolConfiguration(.init(pointSize: BrowserLayout.splitPaneActionSize.height, weight: .regular))?
        .withSymbolConfiguration(.init(paletteColors: [item.0]))
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleNone
      button.isBordered = false
      button.contentTintColor = item.0
      button.setButtonType(.momentaryChange)
      button.toolTip = item.1
      button.setAccessibilityLabel(item.1)
      button.setAccessibilityIdentifier("split-pane-action-\(index)")
      button.target = self
      button.action = item.3
      button.isEnabled = true
      let hoverImage = NSImage(systemSymbolName: item.2, accessibilityDescription: item.1)?
        .withSymbolConfiguration(.init(pointSize: BrowserLayout.splitPaneActionSize.height, weight: .regular))?
        .withSymbolConfiguration(.init(paletteColors: [.black.withAlphaComponent(0.65), item.0]))
      content.addAction(button, hoverImage: hoverImage)
      buttons.append(button)
    }
    let spacing = BrowserLayout.trafficLightSpacing
    let controlsWidth = buttons.reduce(CGFloat.zero) { $0 + $1.frame.width }
      + CGFloat(max(buttons.count - 1, 0)) * spacing
    var x = (content.bounds.width - controlsWidth) / 2
    for button in buttons {
      button.frame.origin = CGPoint(x: x, y: (content.bounds.height - button.frame.height) / 2)
      x = button.frame.maxX + spacing
    }
    capsule.contentView = content
    capsule.isHidden = true
    addSubview(capsule)
  }

  func place(in contentHost: NSView, chromeHost: NSView?, paneFrame: CGRect,
             addressFrame: CGRect?, visible: Bool) {
    isHidden = !visible
    if !visible { collapse(); return }
    guard let chromeHost else { return }
    // Page chrome can mount its address overlay during layout. Keep this
    // floating control above it so the capsule owns clicks in the covered area.
    if superview !== chromeHost || chromeHost.subviews.last !== self {
      chromeHost.addSubview(self, positioned: .above, relativeTo: nil)
    }
    let centre = addressFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
      ?? CGPoint(x: paneFrame.midX, y: paneFrame.minY - BrowserLayout.chromeThickness / 2)
    let handleSize = BrowserLayout.splitPaneHandleSize
    // Use the existing upper gap above the centered address control. No toolbar
    // sizing, safe-area adjustment or extra spacing participates in this overlay.
    let upperGap = (BrowserLayout.chromeThickness - AddressCapsuleLayout.height) / 2
    let top = paneFrame.minY - BrowserLayout.chromeThickness + (upperGap - handleSize.height) / 2
    collapsedFrame = contentHost.convert(CGRect(x: centre.x - handleSize.width / 2,
      y: top, width: handleSize.width, height: handleSize.height), to: chromeHost)
    let size = BrowserLayout.splitPaneCapsuleSize
    // Expanded actions float directly over the address capsule's centre.
    expandedFrame = contentHost.convert(CGRect(x: centre.x - size.width / 2,
      y: centre.y - size.height / 2, width: size.width, height: size.height), to: chromeHost)
    frame = expanded ? expandedFrame : collapsedFrame
    handle.frame = bounds
    capsule.frame = bounds
  }

  func containsControl(at point: CGPoint) -> Bool {
    !isHiddenOrHasHiddenAncestor && window != nil && bounds.contains(convert(point, from: nil))
  }

  func addressLayoutDidChange() {
    guard let superview, collapsedFrame.width > 0,
          let addressFrame = addressFrameProvider?() else { return }
    let anchor = superview.convert(addressFrame, from: nil)
    collapsedFrame.origin.x = anchor.midX - collapsedFrame.width / 2
    expandedFrame.origin = CGPoint(x: anchor.midX - expandedFrame.width / 2,
                                   y: anchor.midY - expandedFrame.height / 2)
    frame = expanded ? expandedFrame : collapsedFrame
    handle.frame = bounds
    capsule.frame = bounds
  }

  func collapse() {
    guard expanded else { return }
    expanded = false
    handle.isHidden = false
    actionContent.setHovered(false)
    capsule.isHidden = true
    if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
    dismissalMonitor = nil
    resize(animated: true)
  }

  private func resize(animated: Bool) {
    let destination = expanded ? expandedFrame : collapsedFrame
    let size = destination.size
    // Exchange controls at their resting height, then animate the width.
    frame.origin.y = destination.minY
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0
      animator().frame = destination
      capsule.animator().frame = CGRect(origin: .zero, size: size)
      handle.frame = CGRect(origin: .zero, size: size)
    }
  }

  @objc private func toggleCapsule() {
    if expanded { collapse(); return }
    addressLayoutDidChange()
    expanded = true
    capsule.isHidden = false
    handle.isHidden = true
    resize(animated: true)
    actionContent.updateTrackingAreas()
    dismissalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown {
        if event.keyCode == 53 { self.collapse(); return nil }
      } else if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
        self.collapse()
      }
      return event
    }
  }
  @objc private func closePage() { collapse(); onClose?() }
  @objc private func minimizePage() { collapse(); onMinimize?() }
  @objc private func expandPage() { collapse(); onExpand?() }

  deinit { if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) } }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Group rollover changes only the ordinary buttons' SF Symbol artwork.
/// Button activation, accessibility and pane-scoped actions stay unchanged.
private final class SplitPaneActionContentView: NSView {
  private var actions: [(button: NSButton, idle: NSImage?, hover: NSImage?)] = []
  private var rolloverArea: NSTrackingArea?
  private var hovered = false

  func addAction(_ button: NSButton, hoverImage: NSImage?) {
    actions.append((button, button.image, hoverImage))
    addSubview(button)
  }

  func actionButton(at point: NSPoint, from source: NSView?) -> NSButton? {
    actions.first {
      !$0.button.isHiddenOrHasHiddenAncestor
        && $0.button.bounds.contains($0.button.convert(point, from: source))
    }?.button
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let rolloverArea { removeTrackingArea(rolloverArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    rolloverArea = area
    let pointerInside = window.map {
      $0.isKeyWindow && !isHiddenOrHasHiddenAncestor
        && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
    } ?? false
    setHovered(pointerInside)
  }

  override func mouseEntered(with event: NSEvent) { setHovered(true) }
  override func mouseExited(with event: NSEvent) { setHovered(false) }

  func setHovered(_ hovered: Bool) {
    guard self.hovered != hovered else { return }
    self.hovered = hovered
    for action in actions {
      action.button.image = hovered ? (action.hover ?? action.idle) : action.idle
    }
  }
}

/// Native NSButton keeps keyboard/accessibility activation. Pointer tracking
/// distinguishes a quick click from a hold or intentional drag.
private final class SplitPaneHandleButton: NSButton {
  var onBegin: ((CGPoint) -> Bool)?
  var onMove: ((CGPoint) -> Void)?
  var onEnd: ((Bool) -> Void)?

  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    let start = event.locationInWindow
    let deadline = Date(timeIntervalSinceNow: BrowserLayout.splitPaneHoldDuration)
    var dragging = false
    highlight(true)
    defer { highlight(false) }
    var trackedKeyWindow = window.isKeyWindow
    while window.isVisible {
      if window.isKeyWindow { trackedKeyWindow = true }
      else if trackedKeyWindow { break }
      let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
        until: dragging ? Date(timeIntervalSinceNow: 0.05) : deadline,
        inMode: .eventTracking, dequeue: true)
      guard let next else {
        if !dragging { dragging = onBegin?(start) ?? false; if !dragging { return } }
        continue
      }
      if next.type == .keyDown {
        if next.keyCode == 53 { break }
        continue
      }
      if next.type == .leftMouseUp {
        if !dragging, bounds.contains(convert(next.locationInWindow, from: nil)) { _ = sendAction(action, to: target) }
        if dragging { onEnd?(false) }
        return
      }
      let point = next.locationInWindow
      if !dragging, hypot(point.x - start.x, point.y - start.y) >= 4 {
        dragging = onBegin?(start) ?? false
      }
      if dragging { onMove?(point) }
    }
    if dragging { onEnd?(true) }
  }
}
