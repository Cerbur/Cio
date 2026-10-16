import AppKit
import SwiftUI

/// Move the actual divider at the display's cadence. Text, native controls and
/// live web surfaces lay out at their real sizes throughout the transition.
@MainActor
final class SpaceOverviewLayoutMotion: NSObject {
  private final class TickTarget: NSObject {
    weak var motion: SpaceOverviewLayoutMotion?
    @objc func tick(_ link: CADisplayLink) { motion?.tick() }
  }

  private struct Flight {
    let start: TimeInterval
    let source: CGFloat
    let target: CGFloat
    let velocity: Double
    let spring: Spring
    let duration: TimeInterval
  }

  private weak var splitView: NSSplitView?
  private var displayLink: CADisplayLink?
  private var flight: Flight?
  private let tickTarget = TickTarget()
  private var completion: (() -> Void)?

  func move(_ splitView: NSSplitView, to width: CGFloat, completion: @escaping () -> Void = {}) {
    if flight?.target == width { return }
    let now = CACurrentMediaTime()
    let source = splitView.arrangedSubviews.first?.frame.width ?? width
    let velocity = flight.map {
      $0.spring.velocity(fromValue: $0.source, toValue: $0.target,
        initialVelocity: $0.velocity, time: max(0, now - $0.start))
    } ?? 0
    displayLink?.invalidate()
    displayLink = nil
    flight = nil
    self.splitView = splitView
    self.completion = completion
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(source - width) > 0.5 else {
      splitView.setPosition(width, ofDividerAt: 0)
      self.completion = nil
      completion()
      return
    }
    let spring = Spring(duration: AnimationValues.SpaceOverview.response,
                        bounce: AnimationValues.SpaceOverview.bounce)
    let duration = spring.settlingDuration(fromValue: source, toValue: width,
      initialVelocity: velocity, epsilon: AnimationValues.SpaceOverview.settlingEpsilon)
    flight = Flight(start: now, source: source, target: width, velocity: velocity,
                    spring: spring, duration: duration)
    tickTarget.motion = self
    let link = splitView.displayLink(target: tickTarget, selector: #selector(TickTarget.tick(_:)))
    displayLink = link
    link.add(to: .main, forMode: .common)
  }

  func cancel() {
    displayLink?.invalidate()
    displayLink = nil
    flight = nil
    completion = nil
  }

  private func tick() {
    guard let splitView, let flight else { cancel(); return }
    let elapsed = CACurrentMediaTime() - flight.start
    if elapsed >= flight.duration {
      let completion = completion
      let target = flight.target
      cancel()
      splitView.setPosition(target, ofDividerAt: 0)
      completion?()
    } else {
      let width = flight.spring.value(fromValue: flight.source, toValue: flight.target,
        initialVelocity: flight.velocity, time: elapsed)
      splitView.setPosition(width, ofDividerAt: 0)
    }
  }

  deinit { displayLink?.invalidate() }
}
