import SwiftUI

/// Native Settings scene: sidebar categories and grouped system-style forms.
public struct BrowserSettingsView: View {
  private let openChromiumSettings: @MainActor (URL) -> Bool
  private let readPasswordSettings: @MainActor () -> (provider: Int, status: String)
  private let setPasswordProvider: @MainActor (Int) -> String?
  private let retryApplePasswords: @MainActor () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var failedToOpenSettings = false

  @State private var passwordProvider = 0
  @State private var passwordStatus = ""
  @State private var passwordError: String?

  public init(
    readPasswordSettings: @escaping @MainActor () -> (provider: Int, status: String),
    setPasswordProvider: @escaping @MainActor (Int) -> String?,
    retryApplePasswords: @escaping @MainActor () -> Void,
    openChromiumSettings: @escaping @MainActor (URL) -> Bool
  ) {
    self.readPasswordSettings = readPasswordSettings
    self.setPasswordProvider = setPasswordProvider
    self.retryApplePasswords = retryApplePasswords
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
        Section("密码管理") {
          Picker("密码管理器", selection: Binding(
            get: { passwordProvider },
            set: { value in
              passwordError = setPasswordProvider(value)
              refreshPasswordSettings()
            }
          )) {
            Text("Apple iCloud 密码扩展").tag(0)
            Text("Chromium 内置密码管理").tag(1)
            Text("关闭密码保存与自动填充").tag(2)
          }
          Text(passwordStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
          if passwordProvider == 0 {
            openButton("Apple 官方 iCloud 密码扩展", url: "https://chromewebstore.google.com/detail/icloud-passwords/pejdijmoenmkgeppbflobdenhhabjlaj", symbol: "key.icloud")
            openButton("管理扩展／检查启用状态", url: "chrome://extensions/", symbol: "puzzlepiece.extension")
            Button("手动重试 Apple 连接") {
              retryApplePasswords()
              refreshPasswordSettings()
            }
            Text("需要你手动安装并启用官方扩展，按 Apple 的弹窗授权。Cio 不读取 Apple 密码库；连接失败不会切换密码库。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          openButton("查看与管理 Chromium 密码", url: "chrome://password-manager/passwords", symbol: "key")
          Text("偏好保存在 Chromium Profile 并直接控制引擎。Apple／关闭模式停用 Chromium 密码保存与填充；选择 Chromium／关闭时会停用 Apple 扩展。切回 Apple 后请在扩展管理中启用。已有密码保留，地址和银行卡设置保持独立。")
            .font(.caption)
            .foregroundStyle(.secondary)
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
    .onAppear { refreshPasswordSettings() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CioPasswordSettingsChanged"))) { _ in
      refreshPasswordSettings()
    }
    .alert("无法更改密码管理器", isPresented: Binding(
      get: { passwordError != nil },
      set: { if !$0 { passwordError = nil } }
    )) {
      Button("好", role: .cancel) { passwordError = nil }
    } message: {
      Text(passwordError ?? "")
    }
    .alert("无法打开 Chrome 设置", isPresented: $failedToOpenSettings) {
      Button("好", role: .cancel) {}
    } message: {
      Text("请稍后重试。")
    }
  }

  private func settingsButton(_ title: String, path: String, symbol: String) -> some View {
    openButton(title, url: "chrome://settings/\(path)", symbol: symbol)
  }

  private func openButton(_ title: String, url: String, symbol: String) -> some View {
    Button {
      guard let url = URL(string: url) else { return }
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

  private func refreshPasswordSettings() {
    let settings = readPasswordSettings()
    passwordProvider = settings.provider
    passwordStatus = settings.status
  }

  private var speedPosition: Binding<Double> {
    Binding(
      get: { animations.speed.sliderPosition },
      set: { animations.speed = BrowserAnimationSpeed(sliderPosition: $0) })
  }
}
