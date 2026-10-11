import Foundation

/// Chromium's action state for a specific tab. Icon bytes include dynamic
/// icons and badges; UI never reads the profile itself.
public struct BrowserExtensionAction: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let title: String
  public let isEnabled: Bool
  public let iconPNG: Data

  public init(id: String, name: String, title: String, isEnabled: Bool, iconPNG: Data) {
    self.id = id
    self.name = name
    self.title = title
    self.isEnabled = isEnabled
    self.iconPNG = iconPNG
  }
}
