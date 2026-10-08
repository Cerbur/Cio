import AppKit

/// Native trackpad feedback at drag target boundaries, independent of animation speed.
@MainActor
enum BrowserDragHaptics {
  static func compression() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  static func replacement() {
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
  }
}
