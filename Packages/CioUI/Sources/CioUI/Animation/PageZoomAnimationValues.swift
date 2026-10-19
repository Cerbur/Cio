import Foundation

extension AnimationValues {
  enum PageZoom {
    /// Restarted after each actual zoom change, using the current animation pace.
    @MainActor static var idleDuration: TimeInterval { AnimationValues.duration(1.2) }
  }
}
