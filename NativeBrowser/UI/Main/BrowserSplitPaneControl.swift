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
  nonisolated(unsafe) private var dismissalMonitor: Any?
  private var expanded = false
  private var collapsedFrame = CGRect.zero
  private var expandedFrame = CGRect.zero
  var onDrag: ((BrowserSplitPaneDragEvent) -> Bool)?
  var onClose: (() -> Void)?
  var onMinimize: (() -> Void)?
  var onExpand: (() -> Void)?
  var dragSource: (() -> (CGRect, NSImage?))?
  override var isFlipped: Bool { true }

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
    let content = NSView(frame: CGRect(origin: .zero, size: BrowserLayout.splitPaneCapsuleSize))
    let actions: [(NSColor, String, Selector)] = [
      (.systemRed, "Close Split Page", #selector(closePage)),
      (.systemYellow, "Move Split Page to Sidebar", #selector(minimizePage)),
      (.systemGreen, "Show Page Alone", #selector(expandPage)),
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
      button.action = item.2
      button.isEnabled = true
      content.addSubview(button)
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

  func place(in contentHost: NSView, chromeHost: NSView?, paneFrame: CGRect, visible: Bool) {
    isHidden = !visible
    if !visible { collapse(); return }
    guard let chromeHost else { return }
    if superview !== chromeHost { chromeHost.addSubview(self, positioned: .above, relativeTo: nil) }
    let handleSize = BrowserLayout.splitPaneHandleSize
    // Use the existing upper gap above the centered address control. No toolbar
    // sizing, safe-area adjustment or extra spacing participates in this overlay.
    let upperGap = (BrowserLayout.chromeThickness - AddressCapsuleLayout.height) / 2
    let top = paneFrame.minY - BrowserLayout.chromeThickness + (upperGap - handleSize.height) / 2
    collapsedFrame = contentHost.convert(CGRect(x: paneFrame.midX - handleSize.width / 2,
      y: top, width: handleSize.width, height: handleSize.height), to: chromeHost)
    let size = BrowserLayout.splitPaneCapsuleSize
    // The larger capsule opens below chrome, keeping all toolbar controls clear.
    expandedFrame = contentHost.convert(CGRect(x: paneFrame.midX - size.width / 2,
      y: paneFrame.minY + BrowserLayout.splitPaneControlInset, width: size.width, height: size.height), to: chromeHost)
    frame = expanded ? expandedFrame : collapsedFrame
    handle.frame = bounds
    capsule.frame = bounds
  }

  func containsControl(at point: CGPoint) -> Bool {
    !isHiddenOrHasHiddenAncestor && window != nil && bounds.contains(convert(point, from: nil))
  }

  func collapse() {
    guard expanded else { return }
    expanded = false
    handle.isHidden = false
    capsule.isHidden = true
    if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
    dismissalMonitor = nil
    resize(animated: true)
  }

  private func resize(animated: Bool) {
    let destination = expanded ? expandedFrame : collapsedFrame
    let size = destination.size
    // Jump vertically while exchanging the two controls, then animate width at
    // the resting position. The transition never crosses the address capsule.
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
    expanded = true
    capsule.isHidden = false
    handle.isHidden = true
    resize(animated: true)
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
