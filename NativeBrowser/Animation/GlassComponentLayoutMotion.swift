import AppKit
import SwiftUI

/// Animate a stable native host from its live presentation into its final layout.
/// Layout is assigned once; the compositor moves the complete glass/control tree.
/// Position is critically damped. Size crosses its target and springs back in
/// either direction, using Apple's Spring rather than a hand-written bounce.
@MainActor
final class GlassComponentLayoutMotion {
  struct Velocity: Equatable {
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

    func frame(at time: TimeInterval) -> CGRect {
      let elapsed = max(0, time - startedAt)
      guard elapsed < duration else { return target }
      let center = CGPoint(
        x: positionSpring.value(fromValue: source.midX, toValue: target.midX,
                                initialVelocity: velocity.center.x, time: elapsed),
        y: positionSpring.value(fromValue: source.midY, toValue: target.midY,
                                initialVelocity: velocity.center.y, time: elapsed))
      let minimum = AnimationValues.GlassComponent.minimumDimension
      let size = CGSize(
        width: max(minimum, sizeSpring.value(fromValue: source.width, toValue: target.width,
                                            initialVelocity: velocity.size.width, time: elapsed)),
        height: max(minimum, sizeSpring.value(fromValue: source.height, toValue: target.height,
                                             initialVelocity: velocity.size.height, time: elapsed)))
      return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                    width: size.width, height: size.height)
    }

    func velocity(at time: TimeInterval) -> Velocity {
      let elapsed = max(0, time - startedAt)
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
    guard view.window != nil, view.superview != nil,
          view.frame.width > 0, view.frame.height > 0 else { return nil }
    // A hosting layer's presentation can still describe the previous layout,
    // or be absent before the transaction commits. Falling back to view.frame
    // then captures the destination rather than the visible moving component.
    // Sample geometry AND velocity on the same flight clock in window space.
    let now = CACurrentMediaTime()
    if let flight {
      return Pose(frameInWindow: flight.frame(at: now), velocity: flight.velocity(at: now))
    }
    return Pose(frameInWindow: view.convert(view.bounds, to: nil), velocity: Velocity())
  }

  func animate(_ view: NSView, from pose: Pose?, enabled: Bool) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      flight = nil
      view.layer?.removeAnimation(forKey: Self.animationKey)
      return
    }
    // A page-flight completion or an unrelated layout pass must not truncate
    // this component's longer size spring at the same destination.
    if let parent = view.superview, pose != nil,
       flight?.target == parent.convert(view.frame, to: nil) { return }
    guard enabled,
          let pose, let parent = view.superview, let layer = view.layer else {
      flight = nil
      view.layer?.removeAnimation(forKey: Self.animationKey)
      return
    }
    let targetInWindow = parent.convert(view.frame, to: nil)
    guard pose.frameInWindow != targetInWindow || pose.velocity != Velocity() else { return }
    let target = view.frame
    let positionSpring = Spring(duration: AnimationValues.GlassComponent.positionResponse,
                                bounce: AnimationValues.GlassComponent.positionBounce)
    let sizeSpring = Spring(duration: AnimationValues.GlassComponent.sizeResponse,
                            bounce: AnimationValues.GlassComponent.sizeBounce)
    let epsilon = AnimationValues.GlassComponent.settlingEpsilon
    let duration = max(positionSpring.settlingDuration, sizeSpring.settlingDuration,
      positionSpring.settlingDuration(fromValue: pose.frameInWindow.midX, toValue: targetInWindow.midX,
                                     initialVelocity: pose.velocity.center.x, epsilon: epsilon),
      positionSpring.settlingDuration(fromValue: pose.frameInWindow.midY, toValue: targetInWindow.midY,
                                     initialVelocity: pose.velocity.center.y, epsilon: epsilon),
      sizeSpring.settlingDuration(fromValue: pose.frameInWindow.width, toValue: targetInWindow.width,
                                 initialVelocity: pose.velocity.size.width, epsilon: epsilon),
      sizeSpring.settlingDuration(fromValue: pose.frameInWindow.height, toValue: targetInWindow.height,
                                 initialVelocity: pose.velocity.size.height, epsilon: epsilon))
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
      let time = flight.startedAt + duration * Double(index) / Double(count)
      let frame = parent.convert(flight.frame(at: time), from: nil)
      let scaleX = frame.width / target.width
      let scaleY = frame.height / target.height
      let pivot = CGPoint(x: target.minX + layer.anchorPoint.x * target.width,
                          y: target.minY + layer.anchorPoint.y * target.height)
      var transform = CATransform3DMakeTranslation(
        frame.midX - target.midX + (target.midX - pivot.x) * (1 - scaleX),
        frame.midY - target.midY + (target.midY - pivot.y) * (1 - scaleY), 0)
      transform = CATransform3DScale(transform, scaleX, scaleY, 1)
      return NSValue(caTransform3D: transform)
    }
    animation.duration = duration
    animation.beginTime = layer.convertTime(flight.startedAt, from: nil)
    animation.calculationMode = .linear
    layer.add(animation, forKey: Self.animationKey)
  }
}
