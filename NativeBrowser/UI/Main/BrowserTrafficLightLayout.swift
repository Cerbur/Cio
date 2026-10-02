import AppKit

/// Positions the window-owned widgets without replacing their native titlebar
/// parent, which owns group rollover and the green button's system menu.
@MainActor
enum BrowserTrafficLightLayout {
  private static let toolbarID = NSToolbar.Identifier("cio.native-window-controls")

  static func installTitlebar(in window: NSWindow) {
    // The unified titlebar contains the complete button hit regions at the
    // shell's toolbar centre. The shell still owns its 56-point layout and
    // ignores native safe areas; this adds no extra row or content padding.
    window.toolbarStyle = .unified
    window.titlebarSeparatorStyle = .none
    if window.toolbar?.identifier != toolbarID {
      let toolbar = NSToolbar(identifier: toolbarID)
      toolbar.displayMode = .iconOnly
      toolbar.allowsUserCustomization = false
      window.toolbar = toolbar
    }
  }

  static func layout(_ buttons: [NSButton], in toolbar: NSView) {
    guard let window = toolbar.window,
          !window.styleMask.contains(.fullScreen) else { return }
    let frames = BrowserShellFrames.trafficLightFrames(
      sizes: buttons.map { $0.frame.size }, toolbarHeight: BrowserLayout.chromeThickness)
    var geometryChanged = false
    for (button, frame) in zip(buttons, frames) {
      guard button.window === window, let parent = button.superview else { continue }
      let nativeFrame = parent.convert(frame, from: toolbar)
      if button.frame != nativeFrame {
        button.frame = nativeFrame
        geometryChanged = true
      }
      button.isHidden = false
    }
    if geometryChanged {
      // Let AppKit rebuild its existing rollover regions from the new frames.
      // No custom tracking areas, glyphs or button drawing are introduced.
      var parent = buttons.first?.superview
      while let view = parent {
        view.updateTrackingAreas()
        parent = view.superview
      }
    }
  }
}
