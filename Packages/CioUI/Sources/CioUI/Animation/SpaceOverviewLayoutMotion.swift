import AppKit
import SwiftUI
import Combine

/// One presentation for the two retained sidebar surfaces and the native
/// divider. A gesture and a keyboard transition use exactly the same geometry.
struct SpaceOverviewPresentation: Equatable {
  var progress: CGFloat = 0
  var normalWidth: CGFloat = BrowserLayout.sidebarDefaultWidth
  var overviewWidth: CGFloat = BrowserLayout.sidebarDefaultWidth

  var sidebarWidth: CGFloat { normalWidth + (overviewWidth - normalWidth) * progress }
  var normalOffset: CGFloat { overviewWidth * progress }
  var overviewOffset: CGFloat { -overviewWidth * (1 - progress) }
}

@MainActor
final class SpaceOverviewLayoutMotion: ObservableObject {
  @MainActor private final class TickTarget: NSObject {
    weak var motion: SpaceOverviewLayoutMotion?
    @objc func tick(_ link: CADisplayLink) { motion?.tick() }
  }

  struct Velocity {
    var progress: Double = 0
    var width: Double = 0
  }

  struct Flight {
    let start: TimeInterval
    let source: SpaceOverviewPresentation
    let target: SpaceOverviewPresentation
    let velocity: Velocity
    let spring: Spring
    let duration: TimeInterval

    func presentation(at time: TimeInterval) -> SpaceOverviewPresentation {
      let elapsed = max(0, time - start)
      guard elapsed < duration else { return target }
      return SpaceOverviewPresentation(
        progress: min(1, max(0, spring.value(fromValue: source.progress, toValue: target.progress,
          initialVelocity: velocity.progress, time: elapsed))),
        normalWidth: target.normalWidth,
        overviewWidth: spring.value(fromValue: source.overviewWidth, toValue: target.overviewWidth,
          initialVelocity: velocity.width, time: elapsed))
    }

    func velocity(at time: TimeInterval) -> Velocity {
      let elapsed = max(0, time - start)
      guard elapsed < duration else { return Velocity() }
      return Velocity(progress: spring.velocity(fromValue: source.progress, toValue: target.progress,
        initialVelocity: velocity.progress, time: elapsed),
        width: spring.velocity(fromValue: source.overviewWidth, toValue: target.overviewWidth,
          initialVelocity: velocity.width, time: elapsed))
    }
  }

  // Frame samples belong to native presentation, not SwiftUI's view graph.
  private(set) var presentation = SpaceOverviewPresentation()
  let frames = PassthroughSubject<SpaceOverviewPresentation, Never>()
  @Published private(set) var isTransitioning = false
  private(set) var isInteracting = false
  var isRunning: Bool { flight != nil }
  private weak var splitView: NSSplitView?
  private var displayLink: CADisplayLink?
  private var flight: Flight?
  private let tickTarget = TickTarget()
  private var completion: (() -> Void)?
  private var inputTime: TimeInterval?
  private var inputVelocity = Velocity()
  var onPresentation: ((SpaceOverviewPresentation) -> Void)?

  func preview(_ splitView: NSSplitView, progress: CGFloat,
               normalWidth: CGFloat, overviewWidth: CGFloat) {
    let now = CACurrentMediaTime()
    let progress = min(1, max(0, progress))
    if let previous = inputTime, now > previous {
      inputVelocity.progress = (progress - presentation.progress) / (now - previous)
    } else {
      inputVelocity = Velocity()
    }
    inputTime = now
    stopDisplayLink()
    self.splitView = splitView
    completion = nil
    isInteracting = true
    if !isTransitioning { isTransitioning = true }
    apply(SpaceOverviewPresentation(progress: progress,
      normalWidth: normalWidth, overviewWidth: overviewWidth))
  }

  func move(_ splitView: NSSplitView, presented: Bool, normalWidth: CGFloat,
            overviewWidth: CGFloat, completion: @escaping () -> Void = {}) {
    let now = CACurrentMediaTime()
    let target = SpaceOverviewPresentation(progress: presented ? 1 : 0,
      normalWidth: normalWidth, overviewWidth: overviewWidth)
    if flight?.target == target { return }
    var source = flight?.presentation(at: now) ?? presentation
    var velocity = flight?.velocity(at: now) ?? Velocity()
    if isInteracting, let inputTime,
       now - inputTime < AnimationValues.SpaceOverview.gestureVelocityLifetime {
      velocity = inputVelocity
    }
    if !isTransitioning && presentation.progress == 0 {
      source.normalWidth = normalWidth
      source.overviewWidth = overviewWidth
    }
    stopDisplayLink()
    self.splitView = splitView
    self.completion = completion
    isInteracting = false
    inputTime = nil
    inputVelocity = Velocity()
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, source != target else {
      apply(target)
      isTransitioning = false
      self.completion = nil
      completion()
      return
    }
    let spring = Spring(duration: AnimationValues.SpaceOverview.response,
                        bounce: AnimationValues.SpaceOverview.bounce)
    let duration = max(
      spring.settlingDuration(fromValue: source.progress, toValue: target.progress,
        initialVelocity: velocity.progress, epsilon: AnimationValues.SpaceOverview.settlingEpsilon),
      spring.settlingDuration(fromValue: source.overviewWidth, toValue: target.overviewWidth,
        initialVelocity: velocity.width, epsilon: AnimationValues.SpaceOverview.widthSettlingEpsilon))
    flight = Flight(start: now, source: source, target: target, velocity: velocity,
                    spring: spring, duration: duration)
    if !isTransitioning { isTransitioning = true }
    apply(source)
    tickTarget.motion = self
    let link = splitView.displayLink(target: tickTarget, selector: #selector(TickTarget.tick(_:)))
    displayLink = link
    link.add(to: .main, forMode: .common)
  }

  func cancel() {
    stopDisplayLink()
    completion = nil
    inputTime = nil
    inputVelocity = Velocity()
    isInteracting = false
    isTransitioning = false
  }

  func restoreNormalWidth(_ width: CGFloat) {
    cancel()
    apply(SpaceOverviewPresentation(progress: 0, normalWidth: width,
      overviewWidth: presentation.overviewWidth))
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
    flight = nil
  }

  private func apply(_ value: SpaceOverviewPresentation) {
    guard presentation != value else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    presentation = value
    frames.send(value)
    onPresentation?(value)
    CATransaction.commit()
  }

  private func tick() {
    guard splitView != nil, let flight else { cancel(); return }
    let now = CACurrentMediaTime()
    if now - flight.start >= flight.duration {
      let completion = completion
      let target = flight.target
      stopDisplayLink()
      self.completion = nil
      apply(target)
      isTransitioning = false
      completion?()
    } else {
      apply(flight.presentation(at: now))
    }
  }

  isolated deinit { displayLink?.invalidate() }
}
