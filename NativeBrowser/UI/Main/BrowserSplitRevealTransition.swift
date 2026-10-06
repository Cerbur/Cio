import AppKit
import SwiftUI

/// One motion policy for split entry, departure, preview layout and cancellation.
/// Chromium renders at the destination size once; its stable viewport and native
/// glass share a compositor transform and rounded outline for the whole flight.
enum BrowserSplitRevealTransition {
  // Tune every split-page transition here, including the floating handle card.
  static let cardSize = CGSize(width: 140, height: 196)
  static let durationScale: TimeInterval = 0.75
  static let duration: TimeInterval = 0.48 * durationScale
  static let sidebarDetachFraction = 0.5
  static let exitDuration: TimeInterval = 0.22 * durationScale
  static let layoutDuration: TimeInterval = 0.26 * durationScale
  static let contentFadeDuration: TimeInterval = 0.18 * durationScale
  static let contentWaitDuration: TimeInterval = 1 * durationScale
  private static let replacementScale: CGFloat = 0.94
  static let sampleCount = 120
  static let glassHoldFraction = 0.08
  static let glassFadeFraction = 0.92
  private static let enterEasing: (Float, Float, Float, Float) = (0.32, 0, 0.2, 1)
  private static let layoutEasing: (Float, Float, Float, Float) = (0.18, 0.78, 0.24, 1)
  private static let exitEasing: (Float, Float, Float, Float) = (0.3, 0, 0.65, 1)

  enum Direction {
    case enter, exit, replacementExit, paneLift, sidebarCollapse, sidebarSurvivor, layout
    var isExit: Bool { self == .exit || self == .replacementExit || self == .paneLift || self == .sidebarCollapse }
    var duration: TimeInterval {
      switch self {
      case .enter, .sidebarCollapse: BrowserSplitRevealTransition.duration
      case .sidebarSurvivor: BrowserSplitRevealTransition.duration * (1 - sidebarDetachFraction)
      case .exit, .replacementExit, .paneLift: exitDuration
      case .layout: layoutDuration
      }
    }
    private var controlPoints: (Float, Float, Float, Float) {
      // Reverse the geometry, but settle both ends of the quick exit. A literal
      // mirrored entry curve finishes at high speed and makes the hide snap.
      switch self {
      case .enter, .sidebarCollapse: enterEasing
      case .exit, .replacementExit, .paneLift: exitEasing
      case .layout, .sidebarSurvivor: layoutEasing
      }
    }
    var timingFunction: CAMediaTimingFunction {
      let (x1, y1, x2, y2) = controlPoints
      return CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
    }
    /// Sample in wall-clock time before composing transforms and crop paths.
    /// Easing interpolated *paths* distorts their nonlinear scale compensation,
    /// especially near the small card. Every property uses these same samples.
    func progress(at time: Double) -> CGFloat {
      let time = min(1, max(0, time))
      if time == 0 || time == 1 { return CGFloat(time) }
      let (x1, y1, x2, y2) = controlPoints
      func bezier(_ t: Double, _ a: Float, _ b: Float) -> Double {
        let u = 1 - t
        return 3 * u * u * t * Double(a) + 3 * u * t * t * Double(b) + t * t * t
      }
      var lower = 0.0
      var upper = 1.0
      for _ in 0..<20 {
        let t = (lower + upper) / 2
        if bezier(t, x1, x2) < time { lower = t } else { upper = t }
      }
      return CGFloat(bezier((lower + upper) / 2, y1, y2))
    }

    var animation: Animation {
      let (x1, y1, x2, y2) = controlPoints
      return .timingCurve(Double(x1), Double(y1), Double(x2), Double(y2), duration: duration)
    }
  }

  // Reuse the timing samples across pages and the region boundary. Retargeting
  // a drag need not solve the cubic 120 times again for every visible page.
  private static let enterSamples = (0...sampleCount).map { Direction.enter.progress(at: Double($0) / Double(sampleCount)) }
  private static let exitSamples = (0...sampleCount).map { Direction.exit.progress(at: Double($0) / Double(sampleCount)) }
  private static let layoutSamples = (0...sampleCount).map { Direction.layout.progress(at: Double($0) / Double(sampleCount)) }
  static func progressSamples(_ direction: Direction) -> [CGFloat] {
    switch direction {
    case .enter, .sidebarCollapse: enterSamples
    case .exit, .replacementExit, .paneLift: exitSamples
    case .layout, .sidebarSurvivor: layoutSamples
    }
  }

  static func sidebarPageVisibility(at time: CGFloat) -> CGFloat {
    let amount = min(1, max(0, time / CGFloat(sidebarDetachFraction)))
    return 1 - amount * amount * (3 - 2 * amount)
  }

  /// Geometry is expressed in host coordinates, so an interrupted flight can
  /// continue from its presentation state even when its render size changes.
  struct Geometry {
    var center: CGPoint
    var outline: CGRect
    var scale: CGSize
    var renderSize: CGSize
    var glassOpacity: Float
    var opacity: Float = 1

    static func page(_ pane: CGRect) -> Self {
      Self(center: CGPoint(x: pane.midX, y: pane.midY), outline: pane,
           scale: CGSize(width: 1, height: 1), renderSize: pane.size, glassOpacity: 0)
    }
    static func card(_ card: CGRect, pane: CGRect, group: CGRect) -> Self {
      let scale = max(card.width / group.width, card.height / group.height)
      return Self(center: CGPoint(x: card.midX + (pane.midX - group.midX) * scale,
                                  y: card.midY + (pane.midY - group.midY) * scale),
                  outline: card, scale: CGSize(width: scale, height: scale), renderSize: pane.size, glassOpacity: 1)
    }
    static func replacedPage(_ pane: CGRect) -> Self {
      var result = page(pane)
      result.scale = CGSize(width: replacementScale, height: replacementScale)
      result.outline = pane.insetBy(dx: pane.width * (1 - replacementScale) / 2,
                                   dy: pane.height * (1 - replacementScale) / 2)
      result.opacity = 0
      return result
    }
    func rebased(to size: CGSize) -> Self {
      var result = self
      // Layout changes preserve each axis independently. A full-height page
      // becoming narrower must never zoom vertically; cards still start with
      // a uniform scale, so their reveal retains its app-opening motion.
      result.scale.width *= renderSize.width / size.width
      result.scale.height *= renderSize.height / size.height
      result.renderSize = size
      return result
    }
  }

  @MainActor
  static func capture(_ page: BrowserPagePresentation) -> Geometry {
    let pane = page.viewport.frame
    guard let layer = page.viewport.layer else { return .page(pane) }
    let shown = layer.presentation() ?? layer
    let scale = CGSize(width: max(0.001, shown.transform.m11), height: max(0.001, shown.transform.m22))
    let pivot = CGPoint(x: layer.anchorPoint.x * pane.width, y: layer.anchorPoint.y * pane.height)
    let origin = CGPoint(x: pane.minX + pivot.x + shown.transform.m41 - pivot.x * scale.width,
                         y: pane.minY + pivot.y + shown.transform.m42 - pivot.y * scale.height)
    let crop = (shown.mask as? CAShapeLayer)?.path?.boundingBoxOfPath ?? page.viewport.bounds
    return Geometry(center: CGPoint(x: origin.x + pane.width / 2 * scale.width,
                                    y: origin.y + pane.height / 2 * scale.height),
      outline: CGRect(x: origin.x + crop.minX * scale.width, y: origin.y + crop.minY * scale.height,
                      width: crop.width * scale.width, height: crop.height * scale.height),
      scale: scale, renderSize: pane.size, glassOpacity: page.splitGlassOpacity, opacity: shown.opacity)
  }

  @MainActor
  static func animate(_ page: BrowserPagePresentation, pane: CGRect,
                      from initial: Geometry, to destination: Geometry, direction: Direction,
                      completion: any CAAnimationDelegate) {
    guard let layer = page.viewport.layer, pane.width > 0, pane.height > 0 else { return }
    let initial = initial.rebased(to: pane.size)
    let destination = destination.rebased(to: pane.size)
    page.viewport.frame = pane
    page.viewport.isHidden = false
    page.surface.setSurfaceVisible(true)
    let surfaceFrame = CGRect(origin: .zero, size: pane.size)
    if page.surface.frame != surfaceFrame { page.surface.frame = surfaceFrame }
    // ChromiumContainerView.setFrameSize already lays out the native hosts
    // and notifies CEF synchronously. Forcing the subtree here repeats that
    // work at the exact moment the compositor flight should start.
    // The incoming card stays above the gently receding replacement page.
    layer.zPosition = direction == .replacementExit ? 0 : 1
    page.splitControl.isHidden = true
    if initial.glassOpacity > 0 || destination.glassOpacity > 0 {
      page.beginSplitRevealGlass(direction: direction,
        fromOpacity: initial.glassOpacity, toOpacity: destination.glassOpacity)
    } else {
      // Keep live material for card reveals/exits. Merely making room for a
      // neighbour should not create a second backdrop.
      page.endSplitRevealGlass()
    }
    animate(layer: layer, pane: pane, from: initial, to: destination,
            direction: direction, completion: completion)
  }

  /// The page and its detached sidebar glass use identical compositor samples.
  /// Neither Chromium nor the material's view tree is resized during the flight.
  @MainActor
  static func animate(layer: CALayer, pane: CGRect,
                      from initial: Geometry, to destination: Geometry, direction: Direction,
                      completion: any CAAnimationDelegate) {
    let initial = initial.rebased(to: pane.size)
    let destination = destination.rebased(to: pane.size)
    // AppKit view-backed layers pivot at their origin, not the CALayer centre.
    let pivot = CGPoint(x: layer.anchorPoint.x * pane.width, y: layer.anchorPoint.y * pane.height)
    var transforms: [NSValue] = []
    var outlines: [CGPath] = []
    var opacities: [Float] = []
    for (step, amount) in progressSamples(direction).enumerated() {
      func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
      let outline = CGRect(x: blend(initial.outline.minX, destination.outline.minX),
        y: blend(initial.outline.minY, destination.outline.minY),
        width: blend(initial.outline.width, destination.outline.width),
        height: blend(initial.outline.height, destination.outline.height))
      let scale = CGSize(width: blend(initial.scale.width, destination.scale.width),
                         height: blend(initial.scale.height, destination.scale.height))
      let center = CGPoint(x: blend(initial.center.x, destination.center.x),
                           y: blend(initial.center.y, destination.center.y))
      let transform = CGAffineTransform(a: scale.width, b: 0, c: 0, d: scale.height,
        tx: center.x - pane.minX - pivot.x - (pane.width / 2 - pivot.x) * scale.width,
        ty: center.y - pane.minY - pivot.y - (pane.height / 2 - pivot.y) * scale.height)
      transforms.append(NSValue(caTransform3D: CATransform3DMakeAffineTransform(transform)))
      let opacityAmount = direction == .sidebarCollapse
        ? 1 - sidebarPageVisibility(at: CGFloat(step) / CGFloat(sampleCount)) : amount
      opacities.append(initial.opacity + (destination.opacity - initial.opacity) * Float(opacityAmount))
      let crop = CGRect(x: (outline.minX - center.x) / scale.width + pane.width / 2,
                        y: (outline.minY - center.y) / scale.height + pane.height / 2,
                        width: outline.width / scale.width, height: outline.height / scale.height)
      let radiusX = BrowserLayout.contentCornerRadius / scale.width
      let radiusY = BrowserLayout.contentCornerRadius / scale.height
      outlines.append(CGPath(roundedRect: crop, cornerWidth: radiusX, cornerHeight: radiusY, transform: nil))
    }
    let mask = CAShapeLayer()
    mask.frame = CGRect(origin: .zero, size: pane.size)
    mask.fillColor = NSColor.black.cgColor
    mask.path = outlines.last
    layer.mask = mask
    let transform = CAKeyframeAnimation(keyPath: "transform")
    transform.values = transforms
    transform.delegate = completion
    let outline = CAKeyframeAnimation(keyPath: "path")
    outline.values = outlines
    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    opacity.values = opacities
    for animation in [transform, outline, opacity] {
      animation.duration = direction.duration
      animation.timingFunction = CAMediaTimingFunction(name: .linear)
      // Zero lets Core Animation start at transaction commit. Native material
      // setup must not consume the first part of the flight before it is shown.
      animation.beginTime = 0
      // Hold the final state until cleanup; never expose a full-size exit frame.
      animation.fillMode = .both
      animation.isRemovedOnCompletion = false
    }
    layer.add(transform, forKey: "split-reveal-transform")
    layer.add(opacity, forKey: "split-reveal-opacity")
    mask.add(outline, forKey: "split-reveal-outline")
  }

  static func glassOpacityAnimation(_ direction: Direction, from: Float, to: Float) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.values = (0...sampleCount).map { step in
      let time = Double(step) / Double(sampleCount)
      let entryTime = direction.isExit ? 1 - time : time
      let fade = min(1, max(0, (entryTime - glassHoldFraction) / (glassFadeFraction - glassHoldFraction)))
      // Continuous opacity slope avoids the visible speed changes between the
      // old opacity keyframes. Reversal retains the captured material opacity.
      let dissolve = fade * fade * (3 - 2 * fade)
      let progress = direction.isExit ? 1 - dissolve : dissolve
      return Double(from) + Double(to - from) * progress
    }
    animation.duration = direction.duration
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.fillMode = .both
    animation.isRemovedOnCompletion = false
    return animation
  }
}
