import SwiftUI

/// Three dimensions: spatial color brushes, grain, and glass clarity.
struct BackdropColorMixEditor: View {
  @Binding var mix: BackdropColorMix

  var body: some View {
    Text("主色调混附色调").font(.headline)
    ThemePreviewScene(overlayAllowsHitTesting: true) {
      ThemeBrushField(mix: $mix)
    }
    .frame(height: 210)
    Text("拖动两团颜色的位置，让柔边笔刷在玻璃上交融。")
      .font(.caption).foregroundStyle(.secondary)
    ColorPicker("主色调", selection: color(\.primary), supportsOpacity: false)
    ColorPicker("附色调", selection: color(\.secondary), supportsOpacity: false)
    ThemeSlider(title: "附色笔刷范围", value: $mix.balance)

    Text("磨砂颗粒").font(.headline)
    ThemeSlider(title: "颗粒强度", value: $mix.grain)

    Text("玻璃通透度").font(.headline)
    ThemeSlider(title: "通透度", value: $mix.backgroundContribution)
    Text("0% 更磨砂，背后内容更隐约；100% 更通透，背后内容更明显。颜色笔刷与颗粒保留，玻璃底层始终存在。")
      .font(.caption).foregroundStyle(.secondary)
  }

  private func color(_ key: WritableKeyPath<BackdropColorMix, ThemeColor>) -> Binding<Color> {
    Binding(get: { mix[keyPath: key].color }, set: { mix[keyPath: key] = ThemeColor($0) })
  }
}

private struct ThemeBrushField: View {
  @Binding var mix: BackdropColorMix

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        WindowBackdropEffect(theme: preview)
        handle(primary: true, size: geometry.size)
        handle(primary: false, size: geometry.size)
      }
      .coordinateSpace(name: "themeBrushField")
      .clipShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
    }
    .frame(height: 168)
  }

  private var preview: ShellTheme {
    var theme = ShellTheme()
    theme.blending = .withinWindow
    theme.colorMix = mix
    return theme
  }

  private func handle(primary: Bool, size: CGSize) -> some View {
    let center = primary ? mix.primaryCenter : mix.secondaryCenter
    let color = primary ? mix.primary.color : mix.secondary.color
    return Image(systemName: "circle.fill")
      .font(.system(size: 24)).foregroundStyle(color)
      .frame(width: 34, height: 34)
      .background(.background, in: Circle())
      .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
      .contentShape(Circle())
      .position(x: center.x * size.width, y: center.y * size.height)
      .gesture(DragGesture(coordinateSpace: .named("themeBrushField")).onChanged { drag in
        set(primary: primary, x: drag.location.x / max(1, size.width),
            y: drag.location.y / max(1, size.height))
      })
      .help(primary ? "拖动主色笔刷" : "拖动附色笔刷")
      .accessibilityLabel(primary ? "主色笔刷位置" : "附色笔刷位置")
      .accessibilityValue("横向 \(Int(center.x * 100))%，纵向 \(Int(center.y * 100))%")
      .accessibilityAction(named: Text("向左移动")) { set(primary: primary, x: center.x - 0.05, y: center.y) }
      .accessibilityAction(named: Text("向右移动")) { set(primary: primary, x: center.x + 0.05, y: center.y) }
      .accessibilityAction(named: Text("向上移动")) { set(primary: primary, x: center.x, y: center.y - 0.05) }
      .accessibilityAction(named: Text("向下移动")) { set(primary: primary, x: center.x, y: center.y + 0.05) }
  }

  private func set(primary: Bool, x: Double, y: Double) {
    let point = ThemeBrushPoint(x: min(0.95, max(0.05, x)), y: min(0.9, max(0.1, y)))
    if primary { mix.primaryPosition = point } else { mix.secondaryPosition = point }
  }
}
