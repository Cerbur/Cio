import AppKit

/// The shell supplies geometry only; page controls retain their tab ownership.
@MainActor
protocol BrowserToolbarLayoutHosting: AnyObject {
  var pageControlsLeadingEdge: CGFloat { get }
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
  static let sidebarPinScrollOverlap: CGFloat = 64
  static let sidebarScrollTransitionHeight: CGFloat = 80
  static let sidebarScrollBlurRadius: CGFloat = 24
  static let sidebarSectionDividerHeight: CGFloat = 16
  static let sidebarEmptyPinDropHeight: CGFloat = 8
  static let chromeControlSize: CGFloat = 36
  static let chromeControlSpacing: CGFloat = 10
  static let pageControlInset: CGFloat = 7
  static let trafficLightSpacing: CGFloat = 9
  static let sidebarMinimumWidth: CGFloat = 182
  static let sidebarDefaultWidth = sidebarMinimumWidth
  static let sidebarMaximumWidth: CGFloat = 480
  static let sidebarWidthPreferenceKey = "cio.sidebar.width"
  static let sidebarWidthMigrationKey = "cio.sidebar.width.migrated-to-182"
  static let devToolsDefaultFraction: CGFloat = 0.5
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
