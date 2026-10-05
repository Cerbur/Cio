import AppKit

/// The shell supplies geometry only; page controls retain their tab ownership.
@MainActor
protocol BrowserToolbarLayoutHosting: AnyObject {
  var pageControlsLeadingEdge: CGFloat { get }
  var splitPaneOverlayHost: NSView { get }
}

/// Shared shell metrics. Toolbar height and navigation-rail width always use
/// chromeThickness; changing it moves both Main View edges together.
enum BrowserLayout {
  static let chromeThickness: CGFloat = 56
  static let mainViewEdgeInset: CGFloat = 4
  static let contentCornerRadius: CGFloat = 14
  static let sidebarContentInset: CGFloat = 12
  static let sidebarTopPinSpacing: CGFloat = 9
  static let sidebarTabRowHeight: CGFloat = 36
  static let sidebarSpaceHeaderSpacing: CGFloat = 4
  static let sidebarSpaceHeaderHeight = sidebarTopPinSpacing + sidebarTabRowHeight + sidebarSpaceHeaderSpacing
  // Blur starts at the Space title row's bottom edge; its top edge is hidden.
  static let sidebarScrollHiddenBoundary = sidebarTopPinSpacing
  static let sidebarScrollTransitionHeight = sidebarTabRowHeight
  static let sidebarScrollFadeHeight = sidebarScrollTransitionHeight
  static let sidebarScrollBlurRadius: CGFloat = 18
  static let sidebarRowSpacing: CGFloat = 5
  static let chromeControlSize: CGFloat = 36
  static let chromeControlSpacing: CGFloat = 10
  static let pageControlInset: CGFloat = 7
  static let splitPaneHandleSize = CGSize(width: 36, height: 8)
  static let splitPaneCapsuleSize = CGSize(width: 96, height: 30)
  static let splitPaneActionSize = CGSize(width: 14, height: 14)
  static let splitPaneHoldDuration: TimeInterval = 0.28
  static let trafficLightSpacing: CGFloat = 9
  static let sidebarMinimumWidth: CGFloat = 182
  static let sidebarDefaultWidth = sidebarMinimumWidth
  static let sidebarMaximumWidth: CGFloat = 480
  static let sidebarWidthPreferenceKey = "cio.sidebar.width"
  static let sidebarWidthMigrationKey = "cio.sidebar.width.migrated-to-182"
  static let devToolsDefaultFraction: CGFloat = 0.5
  static let devToolsWindowSize = CGSize(width: 960, height: 640)
  static let devToolsMinimumHeight: CGFloat = 160
  static let inspectedPageMinimumHeight: CGFloat = 120
}

/// Frames in the shell's top-left coordinate system. There is no outer split
/// divider or safe-area padding contributing hidden points to these edges.
struct BrowserShellFrames {
  let toolbar: CGRect
  let navigationRail: CGRect
  let mainView: CGRect

  init(bounds: CGRect, chromeThickness: CGFloat = BrowserLayout.chromeThickness,
       edgeInset: CGFloat = BrowserLayout.mainViewEdgeInset) {
    toolbar = CGRect(x: bounds.minX, y: bounds.minY,
                     width: bounds.width, height: chromeThickness)
    navigationRail = CGRect(x: bounds.minX, y: bounds.minY + chromeThickness,
                            width: chromeThickness, height: max(0, bounds.height - chromeThickness))
    mainView = CGRect(x: bounds.minX + chromeThickness, y: bounds.minY + chromeThickness,
                      width: max(0, bounds.width - chromeThickness - edgeInset),
                      height: max(0, bounds.height - chromeThickness - edgeInset))
  }

  static func trafficLightFrames(sizes: [CGSize], toolbarHeight: CGFloat) -> [CGRect] {
    guard let first = sizes.first else { return [] }
    // Equal red-button top and left margins; all three share the toolbar centre.
    var x = (toolbarHeight - first.height) / 2
    return sizes.map { size in
      let frame = CGRect(x: x, y: (toolbarHeight - size.height) / 2,
                         width: size.width, height: size.height)
      x = frame.maxX + BrowserLayout.trafficLightSpacing
      return frame
    }
  }
}
