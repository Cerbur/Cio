import SwiftUI

/// Native Settings scene: sidebar categories and grouped system-style forms.
struct BrowserSettingsView: View {
  private enum Page: Hashable { case general }
  @State private var selection: Page? = .general
  @ObservedObject private var animations = BrowserAnimationPreferences.shared

  var body: some View {
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
            Text("调整 NativeBrowser 的使用体验。")
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
      }
      .formStyle(.grouped)
      .navigationTitle("通用")
    }
    .frame(minWidth: 700, minHeight: 440)
  }

  private var speedPosition: Binding<Double> {
    Binding(
      get: { animations.speed.sliderPosition },
      set: { animations.speed = BrowserAnimationSpeed(sliderPosition: $0) })
  }
}
