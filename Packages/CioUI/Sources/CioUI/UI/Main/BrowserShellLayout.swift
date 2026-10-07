import AppKit

/// The shell supplies geometry only; page controls retain their tab ownership.
@MainActor
protocol BrowserToolbarLayoutHosting: AnyObject {
  var pageControlsLeadingEdge: CGFloat { get }
  var splitPaneOverlayHost: NSView { get }
}

/// Shared shell metrics. Toolbar height and navigation-rail width always use
/// chromeThickness; changing it moves both Main View edges together.
public enum BrowserLayout {
  public static let chromeThickness: CGFloat = 56
  public static let mainViewEdgeInset: CGFloat = 4
  public static let contentCornerRadius: CGFloat = 14
  public static let sidebarContentInset = sidebarRowSpacing
  public static let sidebarTopPinSpacing: CGFloat = 9
  public static let sidebarTabRowHeight: CGFloat = 36
  public static let sidebarTabCloseButtonWidth: CGFloat = 29
  public static let sidebarTabTrailingInset: CGFloat = 3
  public static let sidebarSplitMemberSpacing: CGFloat = 5
  public static let sidebarSplitSeparatorHeight: CGFloat = 18
  public static let sidebarSplitLabelSpacing: CGFloat = 4
  public static let sidebarTabLabelFontSize: CGFloat = 13
  public static let sidebarTabIconSize: CGFloat = 18
  public static let sidebarTabLabelInset = (sidebarTabRowHeight - sidebarTabIconSize) / 2
  public static let sidebarTabIconSlotWidth: CGFloat = 20
  public static let sidebarTabLabelSpacing: CGFloat = 9
  public static let sidebarSplitLabelFontSize: CGFloat = 12
  public static let sidebarSpaceHeaderSpacing: CGFloat = 4
  public static let sidebarSpaceHeaderHeight = sidebarTopPinSpacing + sidebarTabRowHeight + sidebarSpaceHeaderSpacing
  // Blur starts at the Space title row's bottom edge; its top edge is hidden.
  public static let sidebarScrollHiddenBoundary = sidebarTopPinSpacing
  public static let sidebarScrollTransitionHeight = sidebarTabRowHeight
  public static let sidebarScrollFadeHeight = sidebarScrollTransitionHeight
  public static let sidebarScrollBlurRadius: CGFloat = 18
  public static let sidebarRowSpacing: CGFloat = 5
  // Resting visible glass / hit slots, not merely hosting-view dimensions.
  // See the toolbar control geometry contract in AGENTS.md.
  public static let chromeControlSize: CGFloat = 36
  public static let chromeControlSpacing: CGFloat = 10
  public static let navigationCapsuleEndInset: CGFloat = 1
  public static let navigationCapsuleWidth = 2 * chromeControlSize + 2 * navigationCapsuleEndInset
  public static let pageControlInset: CGFloat = 7
  public static let splitPaneHandleSize = CGSize(width: 36, height: 8)
  public static let splitPaneCapsuleSize = CGSize(width: 96, height: 30)
  public static let splitPaneActionSize = CGSize(width: 14, height: 14)
  public static let splitPaneHoldDuration: TimeInterval = 0.28
  public static let trafficLightSpacing: CGFloat = 9
  public static let sidebarMinimumWidth: CGFloat = 182
  public static let sidebarDefaultWidth = sidebarMinimumWidth
  public static let sidebarMaximumWidth: CGFloat = 480
  public static let sidebarWidthPreferenceKey = "cio.sidebar.width"
  public static let sidebarWidthMigrationKey = "cio.sidebar.width.migrated-to-182"
  public static let devToolsDefaultFraction: CGFloat = 0.5
  public static let devToolsWindowSize = CGSize(width: 960, height: 640)
  public static let devToolsMinimumHeight: CGFloat = 160
  public static let inspectedPageMinimumHeight: CGFloat = 120
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
