import AppKit

/// Native feedback emitted by container layout/preview and gesture transitions, independent
/// of the input source and animation speed.
@MainActor
enum BrowserDragHaptics {
  enum Feedback: Equatable { case compression, replacement, spaceSwitchReady }

  static func perform(_ feedback: Feedback) {
    let pattern: NSHapticFeedbackManager.FeedbackPattern
    switch feedback {
    case .compression, .spaceSwitchReady: pattern = .alignment
    case .replacement: pattern = .levelChange
    }
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
  }
}
