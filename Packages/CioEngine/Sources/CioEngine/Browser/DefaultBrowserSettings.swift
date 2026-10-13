import AppKit
import Combine

@MainActor
public final class DefaultBrowserSettings: ObservableObject {
  @Published public private(set) var isDefault = false
  @Published public private(set) var isChanging = false
  @Published public private(set) var error: String?

  public init() { refresh() }

  public func refresh() {
    isDefault = ["http", "https"].allSatisfy { scheme in
      guard let target = URL(string: "\(scheme)://example.com"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: target) else { return false }
      return app.standardizedFileURL.resolvingSymlinksInPath()
        == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }
  }

  public func requestDefault() {
    guard !isChanging else { return }
    error = nil
    isChanging = true
    setDefault(schemes: ["http", "https"])
  }

  private func setDefault(schemes: [String]) {
    guard let scheme = schemes.first else {
      isChanging = false
      refresh()
      return
    }
    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                            toOpenURLsWithScheme: scheme) { [weak self] failure in
      let failed = failure != nil
      Task { @MainActor in
        guard let self else { return }
        if failed {
          self.error = "未能设为默认浏览器。请在系统设置 → 桌面与程序坞中选择 Cio。"
          self.isChanging = false
          self.refresh()
        } else {
          self.setDefault(schemes: Array(schemes.dropFirst()))
        }
      }
    }
  }
}
