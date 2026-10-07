import Foundation

/// A layout change can deliver a hover callback without any pointer movement.
struct SpotlightHoverGate {
  private var lastLocation: CGPoint?

  mutating func reset(to location: CGPoint) {
    lastLocation = location
  }

  mutating func moved(to location: CGPoint) -> Bool {
    guard let lastLocation else {
      self.lastLocation = location
      return false
    }
    guard hypot(location.x - lastLocation.x, location.y - lastLocation.y) >= 1 else {
      return false
    }
    self.lastLocation = location
    return true
  }
}
