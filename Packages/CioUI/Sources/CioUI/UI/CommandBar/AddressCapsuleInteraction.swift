import Foundation
import CoreGraphics

/// The native event monitor and both overlaid controls share these hit regions.
enum AddressCapsuleInteraction {
  enum Target { case siteInformation, reloadOrStop, address }
  static let controlDiameter: CGFloat = 36

  static func target(at point: CGPoint, in capsule: CGRect, hasSuggestions: Bool) -> Target {
    if !hasSuggestions {
      let radius = controlDiameter / 2
      let faviconCenter = CGPoint(x: capsule.minX + radius, y: capsule.midY)
      let reloadCenter = CGPoint(x: capsule.maxX - radius, y: capsule.midY)
      if contains(point, center: faviconCenter, radius: radius) { return .siteInformation }
      if contains(point, center: reloadCenter, radius: radius) { return .reloadOrStop }
    }
    return .address
  }

  private static func contains(_ point: CGPoint, center: CGPoint, radius: CGFloat) -> Bool {
    let dx = point.x - center.x
    let dy = point.y - center.y
    return dx * dx + dy * dy <= radius * radius
  }
}
