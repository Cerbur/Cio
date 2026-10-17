import Foundation

/// A reversible scrub, shared by entry, exit and an interrupted settling flight.
/// Decide the destination only when fingers lift; crossing a threshold never
/// latches it. Saturating each input also avoids overscroll debt on reversal.
struct SpaceOverviewGesture {
  private(set) var progress: CGFloat
  let originalDestination: Bool

  init(progress: CGFloat, originalDestination: Bool) {
    self.progress = min(1, max(0, progress))
    self.originalDestination = originalDestination
  }

  mutating func scroll(_ delta: CGFloat, travel: CGFloat) {
    guard travel > 0 else { return }
    progress = min(1, max(0, progress + delta / travel))
  }

  var destination: Bool { progress > AnimationValues.SpaceOverview.commitProgress }
}
