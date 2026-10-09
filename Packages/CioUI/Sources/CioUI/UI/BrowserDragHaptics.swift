import AppKit

/// Native feedback emitted by container layout/preview transitions, independent
/// of the input source and animation speed.
@MainActor
enum BrowserDragHaptics {
  enum Feedback: Equatable { case compression, replacement }

  static func perform(_ feedback: Feedback) {
    let pattern: NSHapticFeedbackManager.FeedbackPattern = feedback == .compression ? .alignment : .levelChange
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
  }
}
