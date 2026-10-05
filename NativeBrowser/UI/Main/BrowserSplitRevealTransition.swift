import AppKit

/// The shared viewport animates Chromium and its glass in one compositor tree.
/// A quick departure and a long, quiet settle make the card feel like it opens.
enum BrowserSplitRevealTransition {
  static let duration: TimeInterval = 0.52
  // Hold the glass briefly, then dissolve it through most of the expansion.
  static let glassFadeDuration: TimeInterval = 0.48
  static var glassFadeTimingFunction: CAMediaTimingFunction {
    CAMediaTimingFunction(name: .linear)
  }
  static var timingFunction: CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.2, 1)
  }
}
