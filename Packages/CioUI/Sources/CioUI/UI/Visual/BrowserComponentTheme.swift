import SwiftUI

/// Stable persistence keys and the capabilities of each independently tunable surface.
/// A capability is only offered when the mounted native component consumes it.
enum ThemeComponent: String, CaseIterable, Identifiable, Sendable {
  case sidebar, railSpace, railHistory, railDownloads
  case sidebarButton, navigation, backButton, forwardButton, addressBar
  case addressFocus, splitStable, addressSuggestions
  case tab, topPin, splitGroup, newTab, floatingTab
  case spotlight, spotlightEdge, spotlightSuggestions
  case splitActions, splitPreview, recentTabs, recentSelection
  case zoomIndicator, fullscreenDisclosure, emptyPage

  var id: Self { self }
  var title: String {
    switch self {
    case .sidebar: "Sidebar 底板"
    case .railSpace: "导航栏 · Space"
    case .railHistory: "导航栏 · 历史"
    case .railDownloads: "导航栏 · 下载"
    case .sidebarButton: "工具栏 · 侧栏按钮"
    case .navigation: "工具栏 · 前进／后退胶囊"
    case .backButton: "后退按钮图标"
    case .forwardButton: "前进按钮图标"
    case .addressBar: "地址栏玻璃"
    case .addressFocus: "地址栏聚焦提示"
    case .splitStable: "分屏 Stable 提示"
    case .addressSuggestions: "地址建议选中项"
    case .tab: "普通标签"
    case .topPin: "Top Pin"
    case .splitGroup: "侧栏分屏标签组"
    case .newTab: "新建标签按钮"
    case .floatingTab: "拖动中的标签卡片"
    case .spotlight: "Spotlight 主玻璃"
    case .spotlightEdge: "Spotlight 折射边缘"
    case .spotlightSuggestions: "Spotlight 选中项"
    case .splitActions: "分屏操作胶囊"
    case .splitPreview: "分屏拖入预览"
    case .recentTabs: "最近标签切换面板"
    case .recentSelection: "最近标签选中项"
    case .zoomIndicator: "页面缩放提示"
    case .fullscreenDisclosure: "网页全屏提示"
    case .emptyPage: "空 Space 内容底板"
    }
  }

  var group: String {
    switch self {
    case .sidebar, .railSpace, .railHistory, .railDownloads: "侧栏与导航栏"
    case .sidebarButton, .navigation, .backButton, .forwardButton, .addressBar,
         .addressFocus, .splitStable, .addressSuggestions: "工具栏与地址栏"
    case .tab, .topPin, .splitGroup, .newTab, .floatingTab: "标签与拖动"
    case .spotlight, .spotlightEdge, .spotlightSuggestions: "Spotlight"
    case .splitActions, .splitPreview: "分屏"
    case .recentTabs, .recentSelection: "最近标签"
    case .zoomIndicator, .fullscreenDisclosure, .emptyPage: "页面提示与底板"
    }
  }
  static let groups = ["侧栏与导航栏", "工具栏与地址栏", "标签与拖动", "Spotlight", "分屏", "最近标签", "页面提示与底板"]

  var hasGlass: Bool {
    switch self {
    case .backButton, .forwardButton, .addressFocus, .splitStable, .addressSuggestions,
         .spotlightSuggestions, .splitPreview, .recentSelection: false
    default: true
    }
  }
  var hasHighlight: Bool {
    switch self {
    case .railSpace, .railHistory, .railDownloads, .addressFocus, .splitStable,
         .addressSuggestions, .tab, .topPin, .splitGroup, .newTab,
         .spotlightSuggestions, .splitPreview, .recentSelection: true
    default: false
    }
  }
  var hasIconColor: Bool { self == .backButton || self == .forwardButton || self == .sidebarButton }
  var hasRowFill: Bool { [.tab, .topPin, .splitGroup, .newTab].contains(self) }
}

struct ComponentTheme: Codable, Equatable, Sendable {
  var glassStyle = LiquidGlassStyle.regular
  var glassTint = ThemeColor(.blue)
  var glassTintOpacity = 0.0
  var appearance = ThemeAppearance.system
  /// Nil follows the Space accent (or the system's original icon/outline color).
  var accent: ThemeColor?
  var highlightOpacity = 0.24
  var hoverOpacity = 0.06
  var idleOpacity = 0.0
  var hoverBorderOpacity = 0.0
  var backdrop = ShellTheme()

  func glass(interactive: Bool = false) -> Glass {
    glassStyle.glass
      .tint(glassTintOpacity > 0 ? glassTint.color.opacity(glassTintOpacity) : nil)
      .interactive(interactive)
  }
}

extension SpaceTheme {
  /// The first mixing version persisted a tint-only surface. Restore its
  /// native material while retaining all saved mixture values.
  var sidebarGlassSurface: SidebarSurface { sidebarSurface == .colorMix ? .frosted : sidebarSurface }

  var sidebarColorMix: BackdropColorMix {
    get {
      component(.sidebar).backdrop.colorMix
        ?? .legacy(color: sidebarColor, opacity: sidebarColorOpacity)
    }
    set {
      var sidebar = component(.sidebar)
      sidebar.backdrop.colorMix = newValue
      setComponent(sidebar, for: .sidebar)
      sidebarSurface = sidebarGlassSurface
    }
  }

  /// Missing overrides derive from v1 values. Existing installations keep their
  /// appearance; writing one component never changes another component's values.
  func component(_ id: ThemeComponent) -> ComponentTheme {
    if let saved = components[id.rawValue] { return saved }
    var result = ComponentTheme()
    result.glassStyle = id == .spotlightEdge ? .clear : glassStyle
    result.glassTint = glassTint
    result.glassTintOpacity = id == .spotlightEdge ? 0 : glassTintOpacity
    switch id {
    case .addressFocus: result.highlightOpacity = 1
    case .splitStable: result.highlightOpacity = stableOpacity
    case .tab, .splitGroup, .newTab: result.highlightOpacity = 0.35
    case .topPin:
      result.highlightOpacity = 0.5
      result.idleOpacity = 0.04
      result.hoverBorderOpacity = 0.25
    case .railSpace, .railHistory, .railDownloads: result.highlightOpacity = 0.5
    case .splitPreview:
      result.highlightOpacity = 0.6
      result.backdrop.material = .hudWindow
      result.backdrop.blending = .withinWindow
    default: result.highlightOpacity = selectionOpacity
    }
    return result
  }

  mutating func setComponent(_ value: ComponentTheme, for id: ThemeComponent) {
    components[id.rawValue] = value
  }
  mutating func resetComponent(_ id: ThemeComponent) { components.removeValue(forKey: id.rawValue) }
  func customAccent(for id: ThemeComponent) -> ThemeColor? { component(id).accent ?? accent }
  func accentColor(for id: ThemeComponent) -> Color { customAccent(for: id)?.color ?? .accentColor }
  func highlight(for id: ThemeComponent) -> Color { accentColor(for: id).opacity(component(id).highlightOpacity) }
}

/// Useful for native geometry owners and glass materialize hosts alike. Only
/// the material changes appearance; the native controls remain mounted.
struct ComponentGlassAppearance: ViewModifier {
  let theme: ComponentTheme
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    content.environment(\.colorScheme, theme.appearance.scheme ?? scheme)
  }
}
