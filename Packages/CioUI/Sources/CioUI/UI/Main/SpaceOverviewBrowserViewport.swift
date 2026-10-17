import AppKit

/// A retained render width and a plain moving container keep Chromium live
/// without reflowing its document. Only transition boundaries lay out the split;
/// input samples move this container's origin and the shell clips its content.
@MainActor
final class SpaceOverviewBrowserViewport: NSView {
  let content: NSView
  var retainedWidth: CGFloat? {
    didSet {
      guard oldValue != retainedWidth else { return }
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
  }

  init(content: NSView) {
    self.content = content
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    content.autoresizingMask = []
    addSubview(content)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layout() {
    super.layout()
    let frame = NSRect(x: 0, y: 0, width: retainedWidth ?? bounds.width, height: bounds.height)
    if content.frame != frame { content.frame = frame }
  }

  func refreshContentGeometry() {
    layoutSubtreeIfNeeded()
    // An ancestor moved, but the page's local frame deliberately did not.
    // Refresh its shell-mounted toolbar at the translated window position.
    func refresh(_ view: NSView) {
      if let host = view as? BrowserSurfaceHostView {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
      } else {
        for child in view.subviews { refresh(child) }
      }
    }
    refresh(content)
  }
}
