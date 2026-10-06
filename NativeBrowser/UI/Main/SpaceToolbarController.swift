import AppKit
import SwiftUI

/// Prevent an invisible SwiftUI hosting view from claiming toolbar background.
@MainActor
private final class SpaceSidebarControlHostingView: NSHostingView<ToolbarNativeControlsView> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard rootView.presentation.isVisible else { return nil }
    return super.hitTest(point)
  }
}

/// Main View/Space owns this controller even though the control is mounted in
/// the shell host, outside Main View's rounded clipping boundary.
@MainActor
final class SpaceToolbarController: NSObject {
  private let onToggle: () -> Void
  private let sidebarButton: NSButton
  private let presentation: ToolbarPresentationState
  private let controlHost: SpaceSidebarControlHostingView
  private let layoutMotion = GlassComponentLayoutMotion()

  /// Stable for the controller's lifetime, including section visibility changes.
  var view: NSView { controlHost }

  init(onToggle: @escaping () -> Void) {
    self.onToggle = onToggle
    let presentation = ToolbarPresentationState()
    self.presentation = presentation
    let height = BrowserLayout.chromeControlSize
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: height, height: height))
    button.setButtonType(.momentaryPushIn)
    // The shell is not an NSToolbar. Use the glass bezel itself for native
    // circular hover, press and release feedback over the shared material.
    button.bezelStyle = .glass
    button.borderShape = .circle
    button.controlSize = .large
    button.isBordered = true
    button.showsBorderOnlyWhileMouseInside = true
    button.title = ""
    button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    button.imagePosition = .imageOnly
    button.autoresizingMask = [.width, .height]
    sidebarButton = button
    controlHost = SpaceSidebarControlHostingView(rootView: ToolbarNativeControlsView(
      content: button, presentation: presentation,
      size: NSSize(width: height, height: height)))
    super.init()

    controlHost.wantsLayer = true
    controlHost.safeAreaRegions = []
    controlHost.clipsToBounds = false
    controlHost.frame = button.frame
    button.target = self
    button.action = #selector(toggleSidebar(_:))
    setCollapsed(false)
  }

  func setVisible(_ visible: Bool, animated: Bool) {
    // ToolbarNativeControlsView applies ToolbarComponentVisibility once to the
    // complete native button and glass, retaining the control during transitions.
    presentation.setVisible(visible, animated: animated && controlHost.window != nil)
  }

  func setCollapsed(_ collapsed: Bool) {
    let title = collapsed ? "Show Sidebar" : "Hide Sidebar"
    sidebarButton.toolTip = title
    sidebarButton.setAccessibilityLabel(title)
  }

  /// Attaches the stable control as a shell-host overlay. Both the sidebar
  /// anchor and the window-controls trailing edge are in host coordinates.
  /// The toolbar stays at the host's top edge with no safe-area/titlebar offset.
  func layout(in host: NSView, sidebarAnchor: NSRect, windowControlsTrailingEdge: CGFloat) {
    if controlHost.superview !== host {
      host.addSubview(controlHost, positioned: .above, relativeTo: nil)
    }
    let height = BrowserLayout.chromeControlSize
    let left = max(windowControlsTrailingEdge + BrowserLayout.chromeControlSpacing,
                   sidebarAnchor.minX - height - BrowserLayout.chromeControlSpacing)
    let topInset = (BrowserLayout.chromeThickness - height) / 2
    let y = host.isFlipped ? host.bounds.minY + topInset : host.bounds.maxY - topInset - height
    let frame = NSRect(x: left, y: y, width: height, height: height)
    if controlHost.frame != frame {
      let source = presentation.isVisible ? layoutMotion.capture(controlHost) : nil
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      controlHost.frame = frame
      controlHost.layoutSubtreeIfNeeded()
      layoutMotion.animate(controlHost, from: source, enabled: presentation.isVisible)
      CATransaction.commit()
    }
  }

  /// Reserve the resting layout frame even while hidden or transitioning, so
  /// page-toolbar placement never depends on visibility update ordering.
  func trailingEdge(in view: NSView) -> CGFloat {
    view.convert(controlHost.bounds, from: controlHost).maxX
  }

  /// Include this in BrowserWindowChromeView.isControlAtWindowPoint together
  /// with the page owners' visible navigation/address control exclusions.
  func containsControl(at windowPoint: NSPoint) -> Bool {
    guard presentation.isVisible, !controlHost.isHiddenOrHasHiddenAncestor,
          controlHost.window != nil else { return false }
    return controlHost.bounds.contains(controlHost.convert(windowPoint, from: nil))
  }

  @objc private func toggleSidebar(_ sender: NSButton) { onToggle() }
}
