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

  /// Stable for the controller's lifetime, including section visibility changes.
  var view: NSView { controlHost }

  init(onToggle: @escaping () -> Void) {
    self.onToggle = onToggle
    let presentation = ToolbarPresentationState()
    self.presentation = presentation
    let height = AddressCapsuleLayout.height
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: height, height: height))
    button.setButtonType(.momentaryPushIn)
    button.bezelStyle = .glass
    button.borderShape = .circle
    button.controlSize = .large
    button.isBordered = true
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

    controlHost.safeAreaRegions = []
    controlHost.clipsToBounds = false
    controlHost.frame = button.frame
    button.target = self
    button.action = #selector(toggleSidebar(_:))
    setCollapsed(false)
  }

  func setVisible(_ visible: Bool, animated: Bool) {
    // ToolbarNativeControlsView applies ToolbarComponentVisibility once to the
    // complete native glass button, retaining the control during transitions.
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
    let height = AddressCapsuleLayout.height
    let left = max(windowControlsTrailingEdge + BrowserLayout.chromeControlSpacing,
                   sidebarAnchor.minX - height - BrowserLayout.chromeControlSpacing)
    let topInset = (BrowserLayout.chromeThickness - height) / 2
    let y = host.isFlipped ? host.bounds.minY + topInset : host.bounds.maxY - topInset - height
    let frame = NSRect(x: left, y: y, width: height, height: height)
    if controlHost.frame != frame { controlHost.frame = frame }
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
