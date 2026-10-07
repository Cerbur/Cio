import AppKit
import QuartzCore

/// Animate only the native control's artwork. Hit-test frames never grow with
/// hover, and repeated page/layout callbacks do not restart an unchanged fade.
@MainActor
enum SplitControlMotion {
  static func setVisible(_ visible: Bool, on layer: CALayer?, duration: TimeInterval) {
    guard let layer else { return }
    let opacity: Float = visible ? 1 : 0
    guard layer.opacity != opacity else { return }
    let source = (layer.presentation() ?? layer).opacity
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = opacity
    layer.removeAnimation(forKey: "split-control-visibility")
    // Departing hints must be gone before the first contracting page frame.
    if visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = source
      fade.toValue = opacity
      fade.duration = duration
      fade.timingFunction = timingFunction
      layer.add(fade, forKey: "split-control-visibility")
    }
    CATransaction.commit()
  }

  static func setEmphasized(_ emphasized: Bool, on layer: CALayer?, scale: CGFloat) {
    guard let layer else { return }
    let scale = emphasized ? scale : 1
    var transform = CATransform3DMakeScale(scale, scale, 1)
    // AppKit owns the anchor point. Compensate around the visual centre without
    // moving/resizing the native view or changing its mouse tracking bounds.
    transform.m41 = (0.5 - layer.anchorPoint.x) * layer.bounds.width * (1 - scale)
    transform.m42 = (0.5 - layer.anchorPoint.y) * layer.bounds.height * (1 - scale)
    guard !CATransform3DEqualToTransform(layer.transform, transform) else { return }
    let source = (layer.presentation() ?? layer).transform
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = transform
    layer.removeAnimation(forKey: "split-control-emphasis")
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let animation = CABasicAnimation(keyPath: "transform")
      animation.fromValue = NSValue(caTransform3D: source)
      animation.toValue = NSValue(caTransform3D: transform)
      animation.duration = AnimationValues.SplitControl.hoverDuration
      animation.timingFunction = timingFunction
      layer.add(animation, forKey: "split-control-emphasis")
    }
    CATransaction.commit()
  }

  private static var timingFunction: CAMediaTimingFunction {
    let (x1, y1, x2, y2) = AnimationValues.SplitControl.easing
    return CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
  }
}
