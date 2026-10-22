import SwiftUI

/// Settings describe capabilities of the real component, not a second theme
/// model. Bindings write only the selected component in the selected Space.
struct ComponentThemeEditor: View {
  let component: ThemeComponent
  @Binding var space: SpaceTheme
  @ObservedObject private var themes = BrowserThemePreferences.shared
  private var value: ComponentTheme { space.component(component) }

  var body: some View {
    Text(component.title).font(.headline)
    VStack(alignment: .leading, spacing: 8) {
      ThemePreviewScene { preview }
        .frame(height: 260)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(component.title) 外观预览")
      Label("滚动图文背景，查看玻璃效果", systemImage: "arrow.up.arrow.down")
        .font(.caption).foregroundStyle(.secondary)
    }
    if component == .sidebar { sidebarControls }
    if component.hasGlass && component != .sidebar {
      glassControls
    }
    if component.hasHighlight || component.hasIconColor { colorControls }
    if component.hasRowFill {
      ThemeSlider(title: "悬停填充强度", value: binding(\.hoverOpacity))
      ThemeSlider(title: "静止填充强度", value: binding(\.idleOpacity))
      ThemeSlider(title: "悬停描边强度", value: binding(\.hoverBorderOpacity))
    }
    if component == .splitPreview { backdropControls }
    if component == .navigation {
      Text("两个按钮保留独立操作与状态，共用一块连续玻璃。图标颜色可分别选择“后退按钮图标”和“前进按钮图标”调整。")
        .font(.caption).foregroundStyle(.secondary)
    }
    if component == .addressFocus || component == .splitStable {
      Text("分别设置地址编辑与分屏 Stable 状态的原生焦点环颜色、强度。")
        .font(.caption).foregroundStyle(.secondary)
    }
    Button("还原此组件：\(component.title)") {
      if component == .sidebar {
        let original = SpaceTheme()
        space.sidebarSurface = original.sidebarSurface
        space.sidebarMaterial = original.sidebarMaterial
        space.sidebarOpacity = original.sidebarOpacity
        space.sidebarColor = original.sidebarColor
        space.sidebarColorOpacity = original.sidebarColorOpacity
        space.sidebarAppearance = original.sidebarAppearance
      }
      space.resetComponent(component)
    }
  }

  private var glassControls: some View {
    Group {
      Picker("玻璃质感", selection: binding(\.glassStyle)) {
        ForEach(LiquidGlassStyle.allCases) { Text($0.title).tag($0) }
      }
      ColorPicker("玻璃染色", selection: colorBinding(\.glassTint), supportsOpacity: false)
      ThemeSlider(title: "玻璃染色强度", value: binding(\.glassTintOpacity))
      Picker("玻璃明暗", selection: binding(\.appearance)) {
        ForEach(ThemeAppearance.allCases) { Text($0.title).tag($0) }
      }
    }
  }

  private var colorControls: some View {
    Group {
      Toggle("颜色跟随 Space", isOn: Binding(
        get: { value.accent == nil },
        set: { follows in update { $0.accent = follows ? nil : ThemeColor(space.accentColor) } }))
      if value.accent != nil {
        ColorPicker(component.hasIconColor ? "图标颜色" : "提示／高亮颜色", selection: Binding(
          get: { space.accentColor(for: component) },
          set: { color in update { $0.accent = ThemeColor(color) } }), supportsOpacity: false)
      }
      if component.hasHighlight {
        ThemeSlider(title: "提示／高亮强度", value: binding(\.highlightOpacity))
      }
    }
  }

  private var sidebarControls: some View {
    BackdropColorMixEditor(mix: $space.sidebarColorMix)
  }

  private var backdropControls: some View {
    BackdropColorMixEditor(mix: Binding(
      get: { value.backdrop.resolvedColorMix },
      set: { next in update { $0.backdrop.colorMix = next } }))
  }

  @ViewBuilder private var preview: some View {
    if component == .sidebar {
      Label(component.title, systemImage: "sidebar.left")
        .frame(width: 160, height: 180)
        .background {
          SidebarGlass(theme: space, previewShell: sidebarPreviewBackdrop)
        }
        .clipShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if component == .splitPreview {
      Label(component.title, systemImage: "rectangle.split.2x1")
        .frame(maxWidth: 240, minHeight: 140)
        .background { WindowBackdropEffect(theme: previewBackdrop) }
        .overlay(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius)
          .strokeBorder(space.highlight(for: component), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
    } else {
      HStack {
        Image(systemName: component.hasIconColor ? "arrow.left" : "rectangle.on.rectangle")
        Text(component.title)
      }
      .foregroundStyle(component.hasIconColor ? space.accentColor(for: component) : .primary)
      .padding(14)
      .background {
        if component.hasHighlight {
          RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius)
            .fill(space.highlight(for: component))
        }
      }
      .glassEffect(component.hasGlass ? value.glass() : .identity,
                   in: RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
      .modifier(ComponentGlassAppearance(theme: value))
      .frame(maxWidth: .infinity)
    }
  }

  private var previewBackdrop: ShellTheme {
    var backdrop = value.backdrop
    // The settings sample samples its own document rather than the desktop.
    backdrop.blending = .withinWindow
    return backdrop
  }

  private var sidebarPreviewBackdrop: ShellTheme {
    var backdrop = themes.shell
    backdrop.blending = .withinWindow
    return backdrop
  }

  private func update(_ change: (inout ComponentTheme) -> Void) {
    var next = value
    change(&next)
    space.setComponent(next, for: component)
  }
  private func binding<T>(_ key: WritableKeyPath<ComponentTheme, T>) -> Binding<T> {
    Binding(get: { value[keyPath: key] }, set: { next in update { $0[keyPath: key] = next } })
  }
  private func colorBinding(_ key: WritableKeyPath<ComponentTheme, ThemeColor>) -> Binding<Color> {
    Binding(get: { value[keyPath: key].color }, set: { next in update { $0[keyPath: key] = ThemeColor(next) } })
  }
}
