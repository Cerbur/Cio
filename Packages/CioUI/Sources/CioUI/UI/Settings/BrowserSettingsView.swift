import SwiftUI

/// Native Settings scene: sidebar categories and grouped system-style forms.
public struct BrowserSettingsView: View {
  private let openChromiumSettings: @MainActor (URL) -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var failedToOpenSettings = false

  public init(openChromiumSettings: @escaping @MainActor (URL) -> Bool) {
    self.openChromiumSettings = openChromiumSettings
  }
  private enum Page: Hashable { case general }
  @State private var selection: Page? = .general
  @ObservedObject private var animations = BrowserAnimationPreferences.shared

  public var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Label("通用", systemImage: "gearshape")
          .tag(Page.general)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    } detail: {
      Form {
        Section {
          VStack(spacing: 10) {
            Image(systemName: "gearshape.fill")
              .font(.system(size: 42, weight: .medium))
              .foregroundStyle(.secondary)
            Text("通用")
              .font(.largeTitle.bold())
            Text("调整 Cio 的使用体验。")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 22)
        }

        Section("动画效果") {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              Text("动画速度")
              Spacer()
              Text(animations.speed.title)
                .foregroundStyle(.secondary)
            }
            Slider(value: speedPosition, in: 0...2, step: 1) {
              Text("动画速度")
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityValue(animations.speed.title)
            HStack {
              ForEach(BrowserAnimationSpeed.allCases) { speed in
                if speed != .detailed { Spacer() }
                Text(speed.title)
                  .foregroundStyle(animations.speed == speed ? .primary : .secondary)
              }
            }
            .font(.caption)
            .accessibilityHidden(true)
            Text("控制分屏、侧栏、工具栏和新标签页等界面动画的速度。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
        }
        Section("浏览器设置") {
          settingsButton("Chrome 设置", path: "", symbol: "slider.horizontal.3")
          settingsButton("首选语言", path: "languages", symbol: "globe")
          settingsButton("Cookie 与网站数据", path: "content/all", symbol: "externaldrive")
          settingsButton("第三方 Cookie", path: "cookies", symbol: "hand.raised")
          settingsButton("隐私与安全", path: "privacy", symbol: "lock.shield")
          Text("首选语言初始使用系统语言，可在 Chrome 设置中调整。Cookie 与网站数据会保存在本机，退出后保留。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("通用")
    }
    .frame(minWidth: 700, minHeight: 440)
    .alert("无法打开 Chrome 设置", isPresented: $failedToOpenSettings) {
      Button("好", role: .cancel) {}
    } message: {
      Text("请稍后重试。")
    }
  }

  private func settingsButton(_ title: String, path: String, symbol: String) -> some View {
    Button {
      guard let url = URL(string: "chrome://settings/\(path)") else { return }
      guard openChromiumSettings(url) else {
        failedToOpenSettings = true
        return
      }
      dismiss()
    } label: {
      HStack {
        Label(title, systemImage: symbol)
        Spacer()
        Image(systemName: "arrow.up.forward")
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityHint("在 Cio 的标签页中打开")
  }

  private var speedPosition: Binding<Double> {
    Binding(
      get: { animations.speed.sliderPosition },
      set: { animations.speed = BrowserAnimationSpeed(sliderPosition: $0) })
  }
}
