import AppKit
import Combine

enum BrowserChromeSize: String, CaseIterable, Identifiable {
  case small, standard

  var id: String { rawValue }
  var title: String { self == .small ? "小号" : "标准" }
  var scale: CGFloat { self == .small ? 0.5 : 1 }
}

/// Resolve usable control geometry from shell space, rather than shrinking
/// every dimension equally. Standard stays unchanged; compact content retains
/// enough height for native glass and text, with matching square action slots.
struct BrowserChromeMetrics {
  let scale: CGFloat
  var thickness: CGFloat { 56 * scale }
  var controlSize: CGFloat { min(thickness, max(22, 36 * scale)) }
  var controlSpacing: CGFloat { (thickness - controlSize) / 2 }
  var navigationWidth: CGFloat { 2 * controlSize + 2 * BrowserLayout.navigationCapsuleEndInset }
  var contentScale: CGFloat { controlSize / 36 }
  // Symbols shrink less than their containers so compact controls stay legible.
  var symbolScale: CGFloat { contentScale.squareRoot() }
  func symbolSize(_ standardSize: CGFloat) -> CGFloat { standardSize * symbolScale }
  var textSize: CGFloat { 12 + min(1, max(0, (controlSize - 22) / 14)) }
  var addressWidthScale: CGFloat { symbolScale }
  var pageControlInset: CGFloat { 7 * contentScale }
  var nativeControlSize: NSControl.ControlSize {
    controlSize < 28 ? .small : controlSize < 32 ? .regular : .large
  }
  var splitHandleSize: CGSize {
    CGSize(width: 36 * contentScale, height: min(8, controlSpacing * 0.8))
  }
  var splitCapsuleSize: CGSize { CGSize(width: 96 * symbolScale, height: 30 * symbolScale) }
  var splitActionSize: CGSize { CGSize(width: 14 * symbolScale, height: 14 * symbolScale) }
}

/// Geometry used by the page owner in both single and split panes. Width is
/// budgeted after navigation so a narrow pane never stretches or clips a pill.
struct BrowserPageToolbarFrames {
  let navigation: CGRect
  let address: CGRect

  init(bounds: CGRect, reservedLeadingEdge: CGFloat, metrics: BrowserChromeMetrics) {
    let inset = metrics.pageControlInset
    let navigationLeft = max(bounds.minX + inset, reservedLeadingEdge + metrics.controlSpacing)
    navigation = CGRect(x: navigationLeft, y: bounds.midY - metrics.controlSize / 2,
                        width: metrics.navigationWidth, height: metrics.controlSize)
    let addressLeadingEdge = navigation.maxX + inset
    let availableWidth = max(0, bounds.maxX - inset - addressLeadingEdge)
    let preferredWidth = bounds.width * 0.45 * metrics.addressWidthScale
    let width = min(availableWidth, max(180 * metrics.symbolScale, preferredWidth))
    address = CGRect(x: min(max(bounds.midX - width / 2, addressLeadingEdge), bounds.maxX - inset - width),
                     y: bounds.midY - metrics.controlSize / 2, width: width, height: metrics.controlSize)
  }
}

@MainActor
final class BrowserChromePreferences: ObservableObject {
  static let shared = BrowserChromePreferences()
  @Published var size: BrowserChromeSize {
    didSet {
      guard oldValue != size else { return }
      UserDefaults.standard.set(size.rawValue, forKey: BrowserLayout.chromeSizePreferenceKey)
      NotificationCenter.default.post(name: .browserChromeSizeDidChange, object: self)
    }
  }

  private init() { size = BrowserLayout.chromeSize }
}

extension Notification.Name {
  static let browserChromeSizeDidChange = Notification.Name("browser.chromeSizeDidChange")
}

/// The shell supplies geometry only; page controls retain their tab ownership.
@MainActor
protocol BrowserToolbarLayoutHosting: AnyObject {
  var pageControlsLeadingEdge: CGFloat { get }
  var splitPaneOverlayHost: NSView { get }
}

/// Shared shell metrics. Toolbar height and navigation-rail width always use
/// chromeThickness; changing it moves both Main View edges together.
public enum BrowserLayout {
  static let chromeSizePreferenceKey = "browser.chromeSize"
  static var chromeSize: BrowserChromeSize {
    UserDefaults.standard.string(forKey: chromeSizePreferenceKey)
      .flatMap(BrowserChromeSize.init(rawValue:)) ?? .standard
  }
  static var chromeMetrics: BrowserChromeMetrics { BrowserChromeMetrics(scale: chromeSize.scale) }
  public static var chromeThickness: CGFloat { chromeMetrics.thickness }
  public static let mainViewEdgeInset: CGFloat = 4
  public static let contentCornerRadius: CGFloat = 14
  public static let webPageSplitDropWidthFraction: CGFloat = 1.0 / 5
  public static let webPageSplitDragDistance: CGFloat = 48
  public static let sidebarContentInset = sidebarRowSpacing
  // Both grid axes use the same internal gap as the Tab rows.
  public static let sidebarTopPinSpacing = sidebarRowSpacing
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
  public static let sidebarSpaceHeaderTopInset: CGFloat = 9
  public static let sidebarSpaceHeaderSpacing: CGFloat = 4
  public static let sidebarSpaceHeaderHeight = sidebarSpaceHeaderTopInset + sidebarTabRowHeight + sidebarSpaceHeaderSpacing
  // Blur starts at the Space title row's bottom edge; its top edge is hidden.
  public static let sidebarScrollHiddenBoundary = sidebarSpaceHeaderTopInset
  public static let sidebarScrollTransitionHeight = sidebarTabRowHeight
  public static let sidebarScrollFadeHeight = sidebarScrollTransitionHeight
  public static let sidebarScrollBlurRadius: CGFloat = 18
  public static let sidebarRowSpacing: CGFloat = 5
  // Resting visible glass / hit slots, not merely hosting-view dimensions.
  // See the toolbar control geometry contract in AGENTS.md.
  public static var chromeControlSize: CGFloat { chromeMetrics.controlSize }
  public static var chromeControlSpacing: CGFloat { chromeMetrics.controlSpacing }
  public static let navigationCapsuleEndInset: CGFloat = 1
  public static var navigationCapsuleWidth: CGFloat { chromeMetrics.navigationWidth }
  public static var pageControlInset: CGFloat { chromeMetrics.pageControlInset }
  static var toolbarSymbolSize: CGFloat { chromeMetrics.symbolSize(15) }
  static var railSymbolSize: CGFloat { chromeMetrics.symbolSize(14.25) }
  static var addressFaviconSize: CGFloat { chromeMetrics.symbolSize(16) }
  static var addressReloadSymbolSize: CGFloat { chromeMetrics.symbolSize(14) }
  static var addressTextSize: CGFloat { chromeMetrics.textSize }
  static var nativeChromeControlSize: NSControl.ControlSize { chromeMetrics.nativeControlSize }
  public static var splitPaneHandleSize: CGSize { chromeMetrics.splitHandleSize }
  static var splitPaneHandleSymbolSize: CGFloat { 13 * chromeMetrics.contentScale }
  public static var splitPaneCapsuleSize: CGSize { chromeMetrics.splitCapsuleSize }
  static let splitPaneCapsuleCornerRadius: CGFloat = 15
  public static var splitPaneActionSize: CGSize { chromeMetrics.splitActionSize }
  static var splitPaneActionSpacing: CGFloat { trafficLightSpacing * chromeMetrics.symbolScale }
  static func fittedCornerRadius(_ nominal: CGFloat, in size: CGSize) -> CGFloat {
    min(nominal, max(0, min(size.width, size.height) / 2))
  }
  public static let splitPaneHoldDuration: TimeInterval = 0.28
  public static let trafficLightSpacing: CGFloat = 9
  public static let sidebarMinimumWidth: CGFloat = 182
  public static let sidebarDefaultWidth = sidebarMinimumWidth
  public static let sidebarMaximumWidth: CGFloat = 480
  static let spaceOverviewMaximumColumnWidth: CGFloat = 240
  static let spaceOverviewColumnSpacing: CGFloat = 8
  static let spaceOverviewMaximumFraction: CGFloat = 0.68
  static let spaceOverviewMinimumBrowserWidth: CGFloat = 320
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
