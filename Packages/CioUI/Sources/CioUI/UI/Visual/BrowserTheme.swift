import AppKit
import Combine
import CioEngine
import SwiftUI

/// Appearance has its own persistence boundary; changing a theme never rewrites tabs.
/// Space keys are durable workspace UUIDs, not names or sidebar positions.
struct ThemeColor: Codable, Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double

  init(_ color: Color) {
    let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
    red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
  }

  var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

enum ThemeAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
  case system, light, dark
  var id: Self { self }
  var title: String {
    switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
  }
  var native: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
  var scheme: ColorScheme? {
    switch self { case .system: nil; case .light: .light; case .dark: .dark }
  }
}

/// Every non-deprecated material exposed by NSVisualEffectView.
enum BackdropMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
  case underWindowBackground, sidebar, titlebar, selection, menu, popover, headerView
  case sheet, windowBackground, hudWindow, fullScreenUI, toolTip, contentBackground, underPageBackground
  var id: Self { self }
  var title: String {
    switch self {
    case .underWindowBackground: "窗口底板（默认）"
    case .sidebar: "侧边栏"
    case .titlebar: "标题栏"
    case .selection: "选中区域"
    case .menu: "菜单"
    case .popover: "弹出面板"
    case .headerView: "页眉"
    case .sheet: "表单面板"
    case .windowBackground: "窗口背景"
    case .hudWindow: "浮动面板 HUD"
    case .fullScreenUI: "全屏界面"
    case .toolTip: "工具提示"
    case .contentBackground: "内容背景"
    case .underPageBackground: "页面底板"
    }
  }
  var native: NSVisualEffectView.Material {
    switch self {
    case .underWindowBackground: .underWindowBackground
    case .sidebar: .sidebar
    case .titlebar: .titlebar
    case .selection: .selection
    case .menu: .menu
    case .popover: .popover
    case .headerView: .headerView
    case .sheet: .sheet
    case .windowBackground: .windowBackground
    case .hudWindow: .hudWindow
    case .fullScreenUI: .fullScreenUI
    case .toolTip: .toolTip
    case .contentBackground: .contentBackground
    case .underPageBackground: .underPageBackground
    }
  }
}

enum BackdropBlending: String, Codable, CaseIterable, Identifiable, Sendable {
  case behindWindow, withinWindow
  var id: Self { self }
  var title: String { self == .behindWindow ? "窗口背后（桌面与其他窗口）" : "窗口内部" }
  var native: NSVisualEffectView.BlendingMode { self == .behindWindow ? .behindWindow : .withinWindow }
}

enum BackdropState: String, Codable, CaseIterable, Identifiable, Sendable {
  case active, followsWindow, inactive
  var id: Self { self }
  var title: String {
    switch self { case .active: "始终活跃"; case .followsWindow: "跟随窗口焦点"; case .inactive: "始终非活跃" }
  }
  var native: NSVisualEffectView.State {
    switch self { case .active: .active; case .followsWindow: .followsWindowActiveState; case .inactive: .inactive }
  }
}

struct ShellTheme: Codable, Equatable, Sendable {
  var material = BackdropMaterial.underWindowBackground
  var blending = BackdropBlending.behindWindow
  var state = BackdropState.active
  var appearance = ThemeAppearance.system
  var emphasized = false
  var opacity = 1.0
  var tint = ThemeColor(.blue)
  var tintOpacity = 0.0
  /// Missing in earlier preferences; nil preserves the original material and tint.
  var colorMix: BackdropColorMix?
}

enum SidebarMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
  case ultraThin, thin, regular, thick, ultraThick
  var id: Self { self }
  var title: String {
    switch self { case .ultraThin: "超薄"; case .thin: "薄"; case .regular: "标准"; case .thick: "厚"; case .ultraThick: "超厚" }
  }
  var material: Material {
    switch self { case .ultraThin: .ultraThinMaterial; case .thin: .thinMaterial; case .regular: .regularMaterial; case .thick: .thickMaterial; case .ultraThick: .ultraThickMaterial }
  }
}

enum SidebarSurface: String, Codable, CaseIterable, Identifiable, Sendable {
  case frosted, liquid, transparent, colorMix
  var id: Self { self }
  var title: String {
    switch self { case .frosted: "毛玻璃材质"; case .liquid: "Liquid Glass"; case .transparent: "透明"; case .colorMix: "高透混色" }
  }
}

enum LiquidGlassStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case regular, clear
  var id: Self { self }
  var title: String { self == .regular ? "标准 Regular" : "通透 Clear" }
  var glass: Glass { self == .regular ? .regular : .clear }
}

struct SpaceTheme: Codable, Equatable, Sendable {
  var accent: ThemeColor? = nil
  var sidebarSurface = SidebarSurface.frosted
  var sidebarMaterial = SidebarMaterial.regular
  var sidebarOpacity = 1.0
  var sidebarColor = ThemeColor(.blue)
  var sidebarColorOpacity = 0.0
  var sidebarAppearance = ThemeAppearance.system
  var glassStyle = LiquidGlassStyle.regular
  var glassTint = ThemeColor(.blue)
  var glassTintOpacity = 0.0
  var selectionOpacity = 0.24
  var stableOpacity = 0.5
  @DefaultThemeComponents var components: [String: ComponentTheme] = [:]

  var accentColor: Color { accent?.color ?? .accentColor }

}

@MainActor
final class BrowserThemePreferences: ObservableObject {
  static let shared = BrowserThemePreferences()
  private static let key = "browser.theme.v1"

  private struct Saved: Codable {
    var version = 1
    var shell = ShellTheme()
    var spaces: [String: SpaceTheme] = [:]
  }

  @Published var shell: ShellTheme { didSet { save() } }
  @Published private var spaces: [String: SpaceTheme]
  @Published private(set) var activeSpaceID: UUID?
  private var workspaceObservation: AnyCancellable?
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    let current = saved?.version == 1 ? saved : nil
    shell = current?.shell ?? ShellTheme()
    spaces = current?.spaces ?? [:]
  }

  func follow(_ workspace: any BrowserWorkspaceProtocol) {
    activeSpaceID = workspace.selectedSpaceID
    workspaceObservation = workspace.objectWillChange.receive(on: RunLoop.main).sink { [weak self, weak workspace] _ in
      guard let self, let workspace, self.activeSpaceID != workspace.selectedSpaceID else { return }
      self.activeSpaceID = workspace.selectedSpaceID
    }
  }

  var active: SpaceTheme { activeSpaceID.map(theme(for:)) ?? SpaceTheme() }
  func theme(for id: UUID) -> SpaceTheme { spaces[id.uuidString] ?? SpaceTheme() }
  func setTheme(_ theme: SpaceTheme, for id: UUID) {
    guard theme != self.theme(for: id) else { return }
    if theme == SpaceTheme() { spaces.removeValue(forKey: id.uuidString) }
    else { spaces[id.uuidString] = theme }
    save()
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(Saved(shell: shell, spaces: spaces)) else { return }
    defaults.set(data, forKey: Self.key)
  }
}

private struct BrowserSpaceThemeKey: EnvironmentKey {
  static let defaultValue: SpaceTheme? = nil
}

extension EnvironmentValues {
  var browserSpaceTheme: SpaceTheme? {
    get { self[BrowserSpaceThemeKey.self] }
    set { self[BrowserSpaceThemeKey.self] = newValue }
  }
}

/// v1 preferences predate per-component keys. Decode an absent dictionary as
/// empty without discarding any existing Space or window settings.
@propertyWrapper
struct DefaultThemeComponents: Codable, Equatable, Sendable {
  var wrappedValue: [String: ComponentTheme] = [:]
  init(wrappedValue: [String: ComponentTheme]) { self.wrappedValue = wrappedValue }
  init(from decoder: Decoder) throws {
    wrappedValue = try decoder.singleValueContainer().decode([String: ComponentTheme].self)
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wrappedValue)
  }
}

extension KeyedDecodingContainer {
  func decode(_ type: DefaultThemeComponents.Type, forKey key: Key) throws -> DefaultThemeComponents {
    try decodeIfPresent(type, forKey: key) ?? DefaultThemeComponents(wrappedValue: [:])
  }
}
