import Foundation

/// OS-delivered links are addresses, never searches or executable schemes.
public enum ExternalWebURL {
  public static func accepts(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      && !(url.host ?? "").isEmpty
  }
}
