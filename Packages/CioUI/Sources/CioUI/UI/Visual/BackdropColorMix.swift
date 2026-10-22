import AppKit
import SwiftUI

struct ThemeBrushPoint: Codable, Equatable, Sendable {
  var x: Double
  var y: Double
  var normalized: CGPoint { CGPoint(x: Self.unit(x), y: Self.unit(y)) }
  private static func unit(_ value: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : 0.5
  }
}

/// Color placement, surface grain, and glass clarity are independent. The
/// historical backgroundContribution key now controls frost, never paint alpha.
struct BackdropColorMix: Codable, Equatable, Sendable {
  static let maximumColorOpacity = 0.32
  var primary = ThemeColor(.cyan)
  var secondary = ThemeColor(.pink)
  var balance = 0.35
  var grain = 0.2
  var backgroundContribution = 0.65
  // Optional keys preserve themes saved before the movable brushes existed.
  var primaryPosition: ThemeBrushPoint?
  var secondaryPosition: ThemeBrushPoint?

  static func legacy(color: ThemeColor, opacity: Double) -> Self {
    var result = Self()
    result.primary = color
    result.secondary = color
    result.balance = 0.5
    result.grain = 0
    result.backgroundContribution = 0
    return result
  }

  var primaryCenter: CGPoint { primaryPosition?.normalized ?? CGPoint(x: 0.22, y: 0.25) }
  var secondaryCenter: CGPoint { secondaryPosition?.normalized ?? CGPoint(x: 0.78, y: 0.75) }
  var primaryRadius: Double { 1.35 - Self.unit(balance) * 0.65 }
  var secondaryRadius: Double { 0.7 + Self.unit(balance) * 0.65 }
  var colorOpacity: Double { Self.maximumColorOpacity }
  var grainOpacity: Double { Self.unit(grain) * 0.12 }
  var frostOpacity: Double { 1 - Self.unit(backgroundContribution) }

  private static func unit(_ value: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : 0
  }
}

struct BackdropTintSurface: NSViewRepresentable {
  let theme: ShellTheme
  func makeNSView(context: Context) -> BackdropTintView { BackdropTintView() }
  func updateNSView(_ view: BackdropTintView, context: Context) { view.apply(theme) }
}

/// Two independent feathered color fields. Neither brush ever becomes an RGB
/// average of the other: overlapping transparent paint does the mixing.
final class BackdropTintView: NSView {
  let primaryBrush = CAGradientLayer()
  let secondaryBrush = CAGradientLayer()
  private let flatTint = CALayer()
  private let grain = BackdropGrainView()
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(flatTint)
    for brush in [primaryBrush, secondaryBrush] {
      brush.type = .radial
      brush.locations = [0, 0.35, 0.72, 1]
      layer?.addSublayer(brush)
    }
    addSubview(grain)
  }

  func apply(_ theme: ShellTheme) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let mix = theme.colorMix {
      flatTint.backgroundColor = nil
      paint(primaryBrush, color: mix.primary, center: mix.primaryCenter,
        radius: mix.primaryRadius, opacity: mix.colorOpacity)
      paint(secondaryBrush, color: mix.secondary, center: mix.secondaryCenter,
        radius: mix.secondaryRadius, opacity: mix.colorOpacity)
      grain.alphaValue = mix.grainOpacity
    } else {
      primaryBrush.colors = nil
      secondaryBrush.colors = nil
      flatTint.backgroundColor = NSColor(theme.tint.color).withAlphaComponent(theme.tintOpacity).cgColor
      grain.alphaValue = 0
    }
    CATransaction.commit()
  }

  private func paint(_ brush: CAGradientLayer, color: ThemeColor, center: CGPoint,
                     radius: Double, opacity: Double) {
    brush.startPoint = center
    brush.endPoint = CGPoint(x: center.x + radius, y: center.y + radius)
    brush.colors = [1.0, 0.88, 0.3, 0].map { NSColor(color.color).withAlphaComponent(opacity * $0).cgColor }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    flatTint.frame = bounds
    primaryBrush.frame = bounds
    secondaryBrush.frame = bounds
    grain.frame = bounds
    CATransaction.commit()
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class BackdropGrainView: NSView {
  private static let texture: NSImage = {
    let side = 128
    var seed: UInt64 = 0xC10
    let bytes = (0..<(side * side)).map { _ -> UInt8 in
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return UInt8(truncatingIfNeeded: seed >> 32)
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: side, height: side, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) else { return NSImage(size: .zero) }
    return NSImage(cgImage: image, size: NSSize(width: CGFloat(side) / 2, height: CGFloat(side) / 2))
  }()

  override var isOpaque: Bool { false }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(patternImage: Self.texture).setFill()
    dirtyRect.fill()
  }
}

extension ShellTheme {
  var resolvedColorMix: BackdropColorMix { colorMix ?? .legacy(color: tint, opacity: tintOpacity) }

  @MainActor
  func apply(to view: NSVisualEffectView, reduceTransparency: Bool) {
    view.material = material.native
    view.blendingMode = blending.native
    view.state = state.native
    view.isEmphasized = emphasized
    view.appearance = appearance.native
    // This is the frost overlay only. ThemeBackdropView keeps native Clear
    // glass underneath at full strength, including at 100% clarity.
    view.alphaValue = reduceTransparency ? 1 : (colorMix?.frostOpacity ?? opacity)
  }
}
