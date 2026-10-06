import AppKit
import SwiftUI

/// One compositor flight crosses the browser/sidebar boundary. Its midpoint
/// changes membership without stopping the material or restarting its easing.
@MainActor
final class BrowserSidebarCollapseView: NSView, CAAnimationDelegate {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private let viewport = CollapseViewport(frame: .zero)
  private let glass = NSGlassEffectView(frame: .zero)
  private let midpointClock = CALayer()
  private var sourceFrame: CGRect
  private var plannedLanding: CGRect?
  private var startTime: CFTimeInterval = 0
  private var midpointAction: (() -> Void)?
  private var completion: (() -> Void)?
  private(set) var isFlightFinished = false

  init(frame: CGRect, sourceInWindow: CGRect) {
    sourceFrame = sourceInWindow
    super.init(frame: frame)
    wantsLayer = true
    autoresizingMask = [.width, .height]
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func prepare() {
    sourceFrame = convert(sourceFrame, from: nil)
    viewport.frame = sourceFrame
    viewport.wantsLayer = true
    viewport.layer?.opacity = 0
    addSubview(viewport)
    glass.frame = viewport.bounds
    glass.style = .regular
    glass.cornerRadius = BrowserLayout.contentCornerRadius
    glass.wantsLayer = true
    glass.layer?.opacity = 0
    glass.setAccessibilityElement(false)
    viewport.addSubview(glass)
    midpointClock.opacity = 0
    layer?.addSublayer(midpointClock)
    viewport.layoutSubtreeIfNeeded()
  }

  func begin(to destinationInWindow: CGRect, label: AnyView,
             onMidpoint: @escaping () -> Void, completion: @escaping () -> Void) {
    let destination = convert(destinationInWindow, from: nil)
    guard let layer = viewport.layer, sourceFrame.width > 0, sourceFrame.height > 0,
          destination.width > 0, destination.height > 0 else {
      onMidpoint()
      isFlightFinished = true
      completion()
      return
    }
    midpointAction = onMidpoint
    self.completion = completion
    plannedLanding = destination
    let direction = BrowserSplitRevealTransition.Direction.sidebarCollapse
    let origin = BrowserSplitRevealTransition.Geometry.page(sourceFrame)
    let landing = BrowserSplitRevealTransition.Geometry.card(destination, pane: sourceFrame, group: sourceFrame)
    let samples = BrowserSplitRevealTransition.progressSamples(direction)
    let glassFade = CAKeyframeAnimation(keyPath: "opacity")
    glassFade.values = samples.enumerated().map { step, amount in
      let time = CGFloat(step) / CGFloat(BrowserSplitRevealTransition.sampleCount)
      // Complete the live-page/material handoff by the logical midpoint.
      return (1 - BrowserSplitRevealTransition.sidebarPageVisibility(at: time))
        * (1 - smooth((amount - 0.9) / 0.1))
    }
    configure(glassFade, direction: direction)
    glass.layer?.add(glassFade, forKey: "sidebar-collapse-glass-fade")

    // Mount at the final row size before starting. There is no hosting-view
    // construction or typography relayout at the midpoint.
    let content = NSHostingView(rootView: label.accessibilityHidden(true))
    content.safeAreaRegions = []
    content.frame = CGRect(x: (sourceFrame.width - destination.width) / 2,
                           y: (sourceFrame.height - destination.height) / 2,
                           width: destination.width, height: destination.height)
    content.wantsLayer = true
    viewport.addSubview(content)
    content.layoutSubtreeIfNeeded()
    if let contentLayer = content.layer {
      let pivot = CGPoint(x: contentLayer.anchorPoint.x * destination.width,
                          y: contentLayer.anchorPoint.y * destination.height)
      let transform = CAKeyframeAnimation(keyPath: "transform")
      transform.values = samples.map { amount -> NSValue in
        let scale = 1 / (1 + (landing.scale.width - 1) * amount)
        let value = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
          tx: (destination.width / 2 - pivot.x) * (1 - scale),
          ty: (destination.height / 2 - pivot.y) * (1 - scale))
        return NSValue(caTransform3D: CATransform3DMakeAffineTransform(value))
      }
      let opacity = CAKeyframeAnimation(keyPath: "opacity")
      opacity.values = samples.map { smooth(($0 - 0.68) / 0.28) }
      for animation in [transform, opacity] { configure(animation, direction: direction) }
      contentLayer.add(transform, forKey: "sidebar-collapse-label-scale")
      contentLayer.add(opacity, forKey: "sidebar-collapse-label-fade")
    }
    startTime = CACurrentMediaTime()
    BrowserSplitRevealTransition.animate(layer: layer, pane: sourceFrame,
      from: origin, to: landing, direction: direction, completion: self)
    let midpoint = CABasicAnimation(keyPath: "opacity")
    midpoint.fromValue = 0
    midpoint.toValue = 0
    midpoint.duration = direction.duration * BrowserSplitRevealTransition.sidebarDetachFraction
    midpoint.delegate = self
    midpoint.setValue(true, forKey: "sidebarCollapseMidpoint")
    midpointClock.add(midpoint, forKey: "sidebar-collapse-midpoint")
  }

  /// Confirm the real row without replacing the main trajectory. A separate
  /// correction starts at zero displacement/velocity and settles at the row.
  func resolveLandingFrame(_ destinationInWindow: CGRect) {
    guard let planned = plannedLanding, let layer else { return }
    let actual = convert(destinationInWindow, from: nil)
    guard actual.width > 0, actual.height > 0, actual != planned else { return }
    let sx = actual.width / planned.width
    let sy = actual.height / planned.height
    let pivot = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
    let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
      tx: actual.midX - pivot.x - (planned.midX - pivot.x) * sx,
      ty: actual.midY - pivot.y - (planned.midY - pivot.y) * sy)
    let correction = CABasicAnimation(keyPath: "transform")
    correction.fromValue = NSValue(caTransform3D: (layer.presentation() ?? layer).transform)
    correction.toValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(transform))
    correction.duration = max(0, BrowserSplitRevealTransition.duration - (CACurrentMediaTime() - startTime))
    correction.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.transform = CATransform3DMakeAffineTransform(transform)
    if correction.duration > 1.0 / 120 { layer.add(correction, forKey: "sidebar-collapse-correction") }
  }

  private func smooth(_ value: CGFloat) -> CGFloat {
    let value = min(1, max(0, value))
    return value * value * (3 - 2 * value)
  }

  private func configure(_ animation: CAAnimation, direction: BrowserSplitRevealTransition.Direction) {
    animation.duration = direction.duration
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.fillMode = .both
    animation.isRemovedOnCompletion = false
  }

  nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
    guard finished else { return }
    let isMidpoint = animation.value(forKey: "sidebarCollapseMidpoint") as? Bool == true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let midpoint = self.midpointAction
      self.midpointAction = nil
      midpoint?()
      if !isMidpoint {
        self.isFlightFinished = true
        let completion = self.completion
        self.completion = nil
        completion?()
      }
    }
  }

  override func removeFromSuperview() {
    // Retained endpoint animations have this view as their delegate. Release
    // them when the row takes over, including cancellation before the midpoint.
    midpointAction = nil
    completion = nil
    midpointClock.removeAllAnimations()
    viewport.layer?.removeAllAnimations()
    glass.layer?.removeAnimation(forKey: "sidebar-collapse-glass-fade")
    for view in viewport.subviews where view !== glass { view.layer?.removeAllAnimations() }
    layer?.removeAnimation(forKey: "sidebar-collapse-correction")
    super.removeFromSuperview()
  }
}

private final class CollapseViewport: NSView {
  override var isFlipped: Bool { true }
}
