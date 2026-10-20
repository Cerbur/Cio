import Foundation

/// Classifies a quick keyboard chord versus holding to browse candidates.
/// This is an input threshold, independent of the visual animation preference.
public struct RecentTabSwitcherActivation: Sendable {
  public static let holdThreshold: TimeInterval = 0.05
  public private(set) var token: UUID?
  public private(set) var deadline: TimeInterval = 0
  public private(set) var isVisible = false

  public init() {}

  @discardableResult
  public mutating func begin(at now: TimeInterval, waitsForControl: Bool) -> UUID {
    let token = UUID()
    self.token = token
    deadline = now + (waitsForControl ? Self.holdThreshold : 0)
    isVisible = !waitsForControl
    return token
  }

  /// A callback from a finished/older chord cannot reveal a newer chooser.
  public mutating func reveal(token: UUID, at now: TimeInterval) -> Bool {
    guard self.token == token, !isVisible, now >= deadline else { return false }
    isVisible = true
    return true
  }

  public mutating func end() {
    token = nil
    isVisible = false
  }
}
