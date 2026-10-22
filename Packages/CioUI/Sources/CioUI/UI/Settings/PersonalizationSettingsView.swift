import CioEngine
import SwiftUI

struct PersonalizationSettingsView: View {
  @ObservedEngine var workspace: any BrowserWorkspaceProtocol
  @ObservedObject private var themes = BrowserThemePreferences.shared
  @State private var editedSpaceID: UUID?
  @State private var editedComponent = ThemeComponent.sidebar

  private var spaceID: UUID? {
    if let editedSpaceID, workspace.spaces.contains(where: { $0.id == editedSpaceID }) { return editedSpaceID }
    return workspace.spaces.first(where: { $0.id == workspace.selectedSpaceID })?.id
  }
  private var space: SpaceTheme { spaceID.map(themes.theme(for:)) ?? SpaceTheme() }

  var body: some View {
    Form {
      Section {
        Text("个性化").font(.largeTitle.bold())
        Text("调整整个窗口的底板，以及每个 Space 的颜色与玻璃质感。更改即时生效并自动保存。")
          .foregroundStyle(.secondary)
      }

      Section {
        BackdropColorMixEditor(mix: Binding(
          get: { themes.shell.resolvedColorMix },
          set: { themes.shell.colorMix = $0 }))
        Button("还原底板默认值") { themes.shell = ShellTheme() }
      } header: {
        Text("1 · 底板玻璃 · 整个窗口")
      } footer: {
        Text("底板覆盖整个窗口，颜色笔刷、磨砂颗粒与玻璃通透度独立调节，更改自动保存。")
      }

      Section {
        if let spaceID {
          Picker("编辑 Space", selection: Binding(get: { spaceID }, set: { editedSpaceID = $0 })) {
            ForEach(workspace.spaces) { Text($0.name).tag($0.id) }
          }
          Text(spaceID == workspace.selectedSpaceID
               ? "正在编辑当前 Space，可直接在浏览器窗口中查看效果。"
               : "正在编辑其他 Space。切换到这个 Space 后会应用其外观。")
            .font(.caption).foregroundStyle(.secondary)

          ThemePreview(shell: themes.shell, space: space)
            .frame(height: 240)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Space 外观预览")

          Toggle("强调色跟随系统", isOn: Binding(
            get: { space.accent == nil },
            set: { system in update { $0.accent = system ? nil : ThemeColor(.accentColor) } }))
          if space.accent != nil {
            ColorPicker("强调色", selection: Binding(
              get: { space.accentColor }, set: { color in update { $0.accent = ThemeColor(color) } }),
              supportsOpacity: false)
          }
          LabeledContent("常用强调色") {
            HStack(spacing: 8) {
              accentButton("蓝色", .blue)
              accentButton("紫色", .purple)
              accentButton("粉色", .pink)
              accentButton("红色", .red)
              accentButton("橙色", .orange)
              accentButton("绿色", .green)
              accentButton("青色", .teal)
            }
          }
          .accessibilityElement(children: .contain)
          Text("用于地址栏聚焦、分屏 Stable 提示、Spotlight 与地址建议的选中高亮。")
            .font(.caption).foregroundStyle(.secondary)
          Divider()
          Picker("编辑组件", selection: $editedComponent) {
            ForEach(ThemeComponent.groups, id: \.self) { group in
              Section(group) {
                ForEach(ThemeComponent.allCases.filter { $0.group == group }) { component in
                  Text(component.title).tag(component)
                }
              }
            }
          }
          Text("每个组件单独保存。颜色默认跟随 Space 强调色，也可为当前组件单独指定。")
            .font(.caption).foregroundStyle(.secondary)
          ComponentThemeEditor(component: editedComponent,
            space: Binding(get: { space }, set: { themes.setTheme($0, for: spaceID) }))
          Divider()
          Button("还原这个 Space 的默认值") { themes.setTheme(SpaceTheme(), for: spaceID) }
        } else {
          Text("创建 Space 后即可设置它的外观。")
        }
      } header: {
        Text("2 · Space · 独立外观")
      } footer: {
        Text("通透度控制背后内容的可见程度，颜色笔刷与颗粒单独保留。系统的“减少透明度”与“增强对比度”优先于这些设置。")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("个性化")
  }

  private func update(_ change: (inout SpaceTheme) -> Void) {
    guard let spaceID else { return }
    var value = themes.theme(for: spaceID)
    change(&value)
    themes.setTheme(value, for: spaceID)
  }
  private func accentButton(_ title: String, _ color: Color) -> some View {
    Button { update { $0.accent = ThemeColor(color) } } label: {
      Image(systemName: "circle.fill").foregroundStyle(color)
    }
    .buttonStyle(.borderless)
    .help(title)
    .accessibilityLabel("强调色：\(title)")
  }

}

struct ThemeSlider: View {
  let title: String
  @Binding var value: Double
  var body: some View {
    LabeledContent(title) {
      HStack {
        Slider(value: $value, in: 0...1).accessibilityLabel(title)
        Text(value, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
      }
      .frame(maxWidth: 240)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct ThemePreview: View {
  let shell: ShellTheme
  let space: SpaceTheme
  var body: some View {
    ThemePreviewScene {
      VStack(spacing: 12) {
        HStack {
          Image(systemName: "sidebar.left")
            .frame(width: 36, height: 36)
            .glassEffect(space.component(.sidebarButton).glass(), in: Circle())
          Spacer()
          Text("cio.app").font(.caption)
            .padding(.horizontal, 36).padding(.vertical, 8)
            .glassEffect(space.component(.addressBar).glass(), in: Capsule())
            .modifier(ComponentGlassAppearance(theme: space.component(.addressBar)))
            .overlay(Capsule().strokeBorder(space.accentColor(for: .addressFocus), lineWidth: 2))
          Spacer()
        }
        .padding(8)
        .background { WindowBackdropEffect(theme: shellPreview) }
        .clipShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
        HStack {
          VStack(alignment: .leading, spacing: 12) {
            Label("Space", systemImage: "square.stack.3d.up")
            Text("选中的标签").padding(8)
              .background(space.highlight(for: .spotlightSuggestions),
                in: RoundedRectangle(cornerRadius: 8))
          }
          .font(.caption).padding(14)
          .frame(width: 150, height: 116, alignment: .topLeading)
          .background {
            SidebarGlass(theme: space, previewShell: shellPreview)
          }
          .clipShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var shellPreview: ShellTheme {
    var preview = shell
    preview.blending = .withinWindow
    return preview
  }
}
