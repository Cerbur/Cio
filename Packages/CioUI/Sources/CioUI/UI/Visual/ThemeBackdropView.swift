import AppKit
import SwiftUI

/// One window-wide native Clear glass sheet. Frost is a separate native
/// material above it; paint and grain belong to the glass's content view.
final class ThemeBackdropView: NSView {
  let clearGlass = NSGlassEffectView()
  let frost = NSVisualEffectView()
  let tint = BackdropTintView()
  private let content = BackdropContentView()
  private var theme = ShellTheme()
  private var excludedRects: [CGRect] = []
  private var maskSize: CGSize = .zero
  private weak var registeredWindow: NSWindow?
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    clearGlass.style = .clear
    clearGlass.cornerRadius = 0
    clearGlass.contentView = content
    content.addSubview(frost)
    content.addSubview(tint)
    addSubview(clearGlass)
  }

  func apply(_ theme: ShellTheme, reduceTransparency: Bool) {
    self.theme = theme
    appearance = theme.appearance.native
    clearGlass.style = .clear
    clearGlass.alphaValue = 1
    theme.apply(to: frost, reduceTransparency: reduceTransparency)
    tint.apply(theme)
    updateRegistration()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateRegistration()
  }

  override func layout() {
    super.layout()
    clearGlass.frame = bounds
    content.frame = bounds
    frost.frame = content.bounds
    tint.frame = content.bounds
    BackdropRegions.refresh(window)
  }

  private func updateRegistration() {
    let previous = registeredWindow
    if let previous, BackdropRegions.roots.object(forKey: previous) === self {
      BackdropRegions.roots.removeObject(forKey: previous)
    }
    registeredWindow = theme.blending == .behindWindow ? window : nil
    if let registeredWindow { BackdropRegions.roots.setObject(self, forKey: registeredWindow) }
    BackdropRegions.refresh(previous)
    BackdropRegions.refresh(registeredWindow)
  }

  fileprivate func excludeFrost(behind regions: [SidebarBackdropRegionView]) {
    let rects = regions.filter { !$0.isHiddenOrHasHiddenAncestor && $0.window === window }
      .map { frost.convert($0.bounds, from: $0).intersection(frost.bounds) }
      .filter { !$0.isEmpty && !$0.isNull }
    guard rects != excludedRects || maskSize != frost.bounds.size else { return }
    excludedRects = rects
    maskSize = frost.bounds.size
    guard !rects.isEmpty, !frost.bounds.isEmpty else {
      frost.maskImage = nil
      tint.layer?.mask = nil
      return
    }
    // Public material mask API. Cut only the sidebar's existing bounds out of
    // the shared frost; its own material can then control clarity independently.
    frost.maskImage = NSImage(size: frost.bounds.size, flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current?.compositingOperation = .copy
      NSColor.clear.setFill()
      for region in rects { region.fill() }
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
    // A Space with its own brushes also replaces the shared color field in
    // this region, so the editor preview and the real sidebar agree.
    let path = CGMutablePath()
    path.addRect(tint.bounds)
    for region in regions where !region.isHiddenOrHasHiddenAncestor && region.window === window {
      path.addRect(tint.convert(region.bounds, from: region))
    }
    let paintMask = CAShapeLayer()
    paintMask.frame = tint.bounds
    paintMask.path = path
    paintMask.fillRule = .evenOdd
    tint.layer?.mask = paintMask
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class BackdropContentView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A per-Space override shares the window's Clear glass. It adds only its own
/// frost and brushes, removing the shared frost under this exact region.
struct SidebarBackdropRegion: NSViewRepresentable {
  let theme: ShellTheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  func makeNSView(context: Context) -> SidebarBackdropRegionView { SidebarBackdropRegionView() }
  func updateNSView(_ view: SidebarBackdropRegionView, context: Context) {
    view.apply(theme, reduceTransparency: reduceTransparency)
  }
  static func dismantleNSView(_ view: SidebarBackdropRegionView, coordinator: ()) { view.unregister() }
}

final class SidebarBackdropRegionView: NSView {
  private let frost = NSVisualEffectView()
  private let tint = BackdropTintView()
  private weak var registeredWindow: NSWindow?
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(frost)
    addSubview(tint)
  }

  func apply(_ theme: ShellTheme, reduceTransparency: Bool) {
    var local = theme
    local.blending = .withinWindow
    local.apply(to: frost, reduceTransparency: reduceTransparency)
    tint.apply(local)
    BackdropRegions.regions.add(self)
    BackdropRegions.refresh(window)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let previous = registeredWindow
    registeredWindow = window
    BackdropRegions.regions.add(self)
    BackdropRegions.refresh(previous)
    BackdropRegions.refresh(window)
  }

  override func layout() {
    super.layout()
    frost.frame = bounds
    tint.frame = bounds
    BackdropRegions.refresh(window)
  }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    BackdropRegions.refresh(window)
  }

  func unregister() {
    BackdropRegions.regions.remove(self)
    BackdropRegions.refresh(registeredWindow)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
private enum BackdropRegions {
  static let roots = NSMapTable<NSWindow, ThemeBackdropView>(keyOptions: .weakMemory, valueOptions: .weakMemory)
  static let regions = NSHashTable<SidebarBackdropRegionView>.weakObjects()
  static func refresh(_ window: NSWindow?) {
    guard let window, let root = roots.object(forKey: window) else { return }
    root.excludeFrost(behind: regions.allObjects)
  }
}
