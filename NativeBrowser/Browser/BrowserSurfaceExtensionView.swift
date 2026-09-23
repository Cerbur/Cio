//
//  BrowserSurfaceExtensionView.swift
//  NativeBrowser
//
//  The browser-side toolbar background extends the live Chromium surface while
//  keeping the browser viewport below the existing 44-point chrome.
//

import AppKit

/// Wraps the stable browser surface in AppKit's native background extension.
/// Chromium remains hosted by BrowserSurfaceHostView; the extension adds only
/// the visual area above that host and does not own any CEF responsibilities.
final class BrowserSurfaceExtensionView: NSBackgroundExtensionView {
  let surfaceHostView = BrowserSurfaceHostView()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    automaticallyPlacesContentView = false
    contentView = surfaceHostView
    surfaceHostView.autoresizingMask = [.width, .height]
    updateSurfaceFrame()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()
    updateSurfaceFrame()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateSurfaceFrame()
  }

  /// The extension fills the browser column, while Chromium starts at the same
  /// top edge it had when its host occupied the area below the SwiftUI toolbar.
  private func updateSurfaceFrame() {
    let top = BrowserChromeLayout.toolbarHeight
    surfaceHostView.frame = NSRect(
      x: 0,
      y: top,
      width: bounds.width,
      height: max(0, bounds.height - top))
  }

  /// The extended band is visual only. Let the SwiftUI toolbar and native
  /// window controls receive events in the area above the browser surface.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = convert(point, from: superview)
    guard localPoint.y >= BrowserChromeLayout.toolbarHeight else { return nil }
    return super.hitTest(point)
  }
}
