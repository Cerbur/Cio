import Foundation

public enum BrowserPresentationLimits {
  public static let titleBytes = 4 * 1024
  public static let faviconBytes = 64 * 1024
  public static let faviconCount = 128
  public static let faviconTotalBytes = 4 * 1024 * 1024

  public static func title(_ value: String) -> String {
    guard value.utf8.count > titleBytes else { return value }
    var bytes = Array(value.utf8.prefix(titleBytes))
    // Remove at most three bytes from an incomplete final Unicode scalar.
    while let _ = bytes.last {
      if let title = String(bytes: bytes, encoding: .utf8) { return title }
      bytes.removeLast()
    }
    return ""
  }

  public static func favicon(_ data: Data?) -> Data? {
    data.flatMap { $0.count <= faviconBytes ? $0 : nil }
  }
}
