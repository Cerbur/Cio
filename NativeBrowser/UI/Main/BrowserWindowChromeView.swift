import AppKit
import Combine

/// Shell-owned window chrome. Page and Space controls are sibling overlays;
/// their owners supply the control exclusion without transferring ownership.
@MainActor
final class BrowserWindowChromeView: NSView {
  /// Return true for visible page chrome or the visible Space sidebar control.
  /// The point is in window coordinates. Native traffic lights are excluded here
  /// before this closure runs and remain in their AppKit titlebar parent.
  var isControlAtWindowPoint: ((NSPoint) -> Bool)?

  private var trafficLights: [NSButton] = []
  private weak var installedWindow: NSWindow?
  private var windowObservations = Set<AnyCancellable>()
  private var frameBeforeMaximizing: NSRect?

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 1, height: BrowserLayout.chromeThickness))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: BrowserLayout.chromeThickness)
  }

  /// Measured in this view's coordinates. Convert to the sidebar host's
  /// coordinates before passing it to SpaceToolbarController.layout.
  var trafficLightsTrailingEdge: CGFloat {
    layoutTrafficLights()
    return trafficLights.last.map { convert($0.bounds, from: $0).maxX } ?? 0
  }

  /// Call after mounting this view in the shell. Repeated installation in the
  /// same window preserves the native buttons and the maximize restore frame.
  func install(in window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    BrowserTrafficLightLayout.installTitlebar(in: window)

    if installedWindow !== window {
      installedWindow = window
      frameBeforeMaximizing = nil
      windowObservations.removeAll()
      trafficLights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        .compactMap { window.standardWindowButton($0) }
      for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                   NSWindow.didExitFullScreenNotification] {
        NotificationCenter.default.publisher(for: name, object: window)
          .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutTrafficLights() }
          }
          .store(in: &windowObservations)
      }
    }
    layoutTrafficLights()
  }

  override func layout() {
    super.layout()
    layoutTrafficLights()
  }

  private func layoutTrafficLights() {
    guard let installedWindow, window === installedWindow else { return }
    BrowserTrafficLightLayout.layout(trafficLights, in: self)
  }

  /// The shell root should use this before testing overlapping toolbar hosts,
  /// returning this view for toolbar background and normal hit-testing otherwise.
  func isWindowInteraction(at windowPoint: NSPoint) -> Bool {
    guard !isHiddenOrHasHiddenAncestor, let window, window === installedWindow,
          window.attachedSheet == nil,
          bounds.contains(convert(windowPoint, from: nil)) else { return false }

    for button in trafficLights where button.window === window && !button.isHiddenOrHasHiddenAncestor {
      if button.bounds.contains(button.convert(windowPoint, from: nil)) { return false }
    }
    return !(isControlAtWindowPoint?(windowPoint) ?? false)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let windowPoint = superview?.convert(point, to: nil) ?? point
    return isWindowInteraction(at: windowPoint) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard event.window === window, isWindowInteraction(at: event.locationInWindow),
          let window else {
      super.mouseDown(with: event)
      return
    }
    if event.clickCount == 2 {
      guard !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
      // Preserve the existing toolbar gesture: maximize within the desktop's
      // available frame, then restore, without a full-screen transition.
      if window.frame == screen.visibleFrame, let frameBeforeMaximizing {
        window.setFrame(frameBeforeMaximizing, display: true, animate: true)
        self.frameBeforeMaximizing = nil
      } else {
        frameBeforeMaximizing = window.frame
        window.setFrame(screen.visibleFrame, display: true, animate: true)
      }
    } else if event.clickCount == 1 {
      window.performDrag(with: event)
    }
  }
}
