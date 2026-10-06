import AppKit
import SwiftUI

/// Animate a stable native host from its live presentation into its final layout.
/// Layout is assigned once; the compositor moves the complete glass/control tree.
/// Position is critically damped. Size crosses its target and springs back in
/// either direction, using Apple's Spring rather than a hand-written bounce.
@MainActor
final class GlassComponentLayoutMotion {
  struct Velocity {
    var center = CGPoint.zero
    var size = CGSize.zero
  }

  struct Pose {
    let frameInWindow: CGRect
    let velocity: Velocity
  }

  private struct Flight {
    let startedAt: TimeInterval
    let source: CGRect
    let target: CGRect
    let velocity: Velocity
    let positionSpring: Spring
    let sizeSpring: Spring
    let duration: TimeInterval

    func velocity(at time: TimeInterval) -> Velocity {
      let elapsed = time - startedAt
      guard elapsed < duration else { return Velocity() }
      return Velocity(center: CGPoint(
        x: positionSpring.velocity(fromValue: source.midX, toValue: target.midX,
                                   initialVelocity: velocity.center.x, time: elapsed),
        y: positionSpring.velocity(fromValue: source.midY, toValue: target.midY,
                                   initialVelocity: velocity.center.y, time: elapsed)),
        size: CGSize(width: sizeSpring.velocity(fromValue: source.width, toValue: target.width,
                                  initialVelocity: velocity.size.width, time: elapsed),
        height: sizeSpring.velocity(fromValue: source.height, toValue: target.height,
                                   initialVelocity: velocity.size.height, time: elapsed)))
    }
  }
  private var flight: Flight?
  private static let animationKey = "glass-component-layout"

  func capture(_ view: NSView) -> Pose? {
    guard view.window != nil, let parent = view.superview,
          view.frame.width > 0, view.frame.height > 0 else { return nil }
    let frame = view.layer?.presentation()?.frame ?? view.frame
    return Pose(frameInWindow: parent.convert(frame, to: nil),
                velocity: flight?.velocity(at: CACurrentMediaTime()) ?? Velocity())
  }

  func animate(_ view: NSView, from pose: Pose?, enabled: Bool) {
    // A page-flight completion or an unrelated layout pass must not truncate
    // this component's longer size spring at the same destination.
    if let parent = view.superview, pose != nil,
       flight?.target == parent.convert(view.frame, to: nil) { return }
    guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          let pose, let parent = view.superview, let layer = view.layer else {
      flight = nil
      view.layer?.removeAnimation(forKey: Self.animationKey)
      return
    }
    let targetInWindow = parent.convert(view.frame, to: nil)
    guard pose.frameInWindow != targetInWindow else { return }
    let source = parent.convert(pose.frameInWindow, from: nil)
    let target = view.frame
    let positionSpring = Spring(duration: AnimationValues.GlassComponent.positionResponse,
                                bounce: AnimationValues.GlassComponent.positionBounce)
    let sizeSpring = Spring(duration: AnimationValues.GlassComponent.sizeResponse,
                            bounce: AnimationValues.GlassComponent.sizeBounce)
    let epsilon = AnimationValues.GlassComponent.settlingEpsilon
    let duration = max(positionSpring.settlingDuration, sizeSpring.settlingDuration,
      positionSpring.settlingDuration(fromValue: pose.frameInWindow.midX, toValue: targetInWindow.midX,
                                     initialVelocity: pose.velocity.center.x, epsilon: epsilon),
      sizeSpring.settlingDuration(fromValue: source.width, toValue: target.width,
                                 initialVelocity: pose.velocity.size.width, epsilon: epsilon))
    let flight = Flight(startedAt: CACurrentMediaTime(), source: pose.frameInWindow,
      target: targetInWindow, velocity: pose.velocity,
      positionSpring: positionSpring, sizeSpring: sizeSpring, duration: duration)
    self.flight = flight
    let count = AnimationValues.GlassComponent.sampleCount
    let animation = CAKeyframeAnimation(keyPath: "transform")
    animation.values = (0...count).map { index in
      // Pin the last sample to identity so removing the animation never corrects
      // a subpixel endpoint. Earlier samples include the spring's overshoot.
      guard index < count else { return NSValue(caTransform3D: CATransform3DIdentity) }
      let time = duration * Double(index) / Double(count)
      let x = positionSpring.value(fromValue: source.midX, toValue: target.midX,
                                   initialVelocity: pose.velocity.center.x, time: time)
      let yVelocity = parent.isFlipped ? -pose.velocity.center.y : pose.velocity.center.y
      let y = positionSpring.value(fromValue: source.midY, toValue: target.midY,
                                   initialVelocity: yVelocity, time: time)
      let width = sizeSpring.value(fromValue: source.width, toValue: target.width,
                                  initialVelocity: pose.velocity.size.width, time: time)
      let height = sizeSpring.value(fromValue: source.height, toValue: target.height,
                                   initialVelocity: pose.velocity.size.height, time: time)
      let minimum = AnimationValues.GlassComponent.minimumDimension
      let scaleX = max(minimum, width) / target.width
      let scaleY = max(minimum, height) / target.height
      let pivot = CGPoint(x: target.minX + layer.anchorPoint.x * target.width,
                          y: target.minY + layer.anchorPoint.y * target.height)
      var transform = CATransform3DMakeTranslation(
        x - target.midX + (target.midX - pivot.x) * (1 - scaleX),
        y - target.midY + (target.midY - pivot.y) * (1 - scaleY), 0)
      transform = CATransform3DScale(transform, scaleX, scaleY, 1)
      return NSValue(caTransform3D: transform)
    }
    animation.duration = duration
    animation.calculationMode = .linear
    layer.add(animation, forKey: Self.animationKey)
  }
}
