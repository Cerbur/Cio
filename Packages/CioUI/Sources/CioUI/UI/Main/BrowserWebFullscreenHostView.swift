import AppKit

/// Lifts the existing page viewport above the complete shell. The hidden shell
/// keeps its sidebar widths, split, native controls and glass identities intact.
public final class BrowserWebFullscreenHostView: NSView {
  let shellContent: NSView
  private var viewport: NSView?
  private var surface: NSView?
  private weak var originalParent: NSView?
  private var originalFrame = CGRect.zero
  private var originalAutoresizing: NSView.AutoresizingMask = []

  public init(shellContent: NSView) {
    self.shellContent = shellContent
    super.init(frame: shellContent.frame)
    wantsLayer = true
    addSubview(shellContent)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  public override var isFlipped: Bool { true }
  var isPresenting: Bool { viewport != nil }

  func present(viewport: NSView?, surface: NSView? = nil) {
    guard self.viewport !== viewport else { return }
    if let previous = self.viewport {
      originalParent?.addSubview(previous)
      previous.autoresizingMask = originalAutoresizing
      previous.frame = originalFrame
    }
    self.viewport = viewport
    self.surface = surface
    originalParent = viewport?.superview
    originalFrame = viewport?.frame ?? .zero
    originalAutoresizing = viewport?.autoresizingMask ?? []
    if let viewport {
      viewport.autoresizingMask = [.width, .height]
      viewport.layer?.mask = nil
      viewport.layer?.cornerRadius = 0
      addSubview(viewport)
      viewport.isHidden = false
    }
    shellContent.isHidden = viewport != nil
    layer?.backgroundColor = viewport == nil ? nil : NSColor.black.cgColor
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public override func layout() {
    super.layout()
    if shellContent.frame != bounds { shellContent.frame = bounds }
    if let viewport {
      if viewport.frame != bounds { viewport.frame = bounds }
      if surface?.frame != viewport.bounds { surface?.frame = viewport.bounds }
    }
  }
}
