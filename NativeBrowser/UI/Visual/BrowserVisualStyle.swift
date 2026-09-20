//
//  BrowserVisualStyle.swift
//  NativeBrowser
//
//  Presentation-only visual helpers for the Milestone 5 browser chrome.
//
//  The app currently targets macOS 26, where SwiftUI's native Liquid Glass
//  modifier is available. The availability branch keeps this helper safe if
//  the deployment target is lowered later: the fallback is still a semantic
//  macOS material and never a hand-built blur or screenshot effect.
//

import AppKit
import SwiftUI

/// Ephemeral presentation state shared by the small hover/focus surfaces. It
/// never mirrors tab selection, browser sessions or navigation state.
@MainActor
final class BrowserInteractionState: ObservableObject {
  @Published var isHovered = false
  @Published var isFocused = false
}

extension View {
  /// Applies the system Liquid Glass treatment to a compact browser control.
  ///
  /// Glass is intentionally reserved for compact interactive chrome such as
  /// the address field. Structural panes use semantic NSVisualEffectView
  /// materials instead, and Chromium content is never passed through either
  /// treatment.
  @ViewBuilder
  func browserCompactGlass(cornerRadius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: shape)
    } else {
      background(.regularMaterial, in: shape)
        .overlay {
          shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
  }
}

/// A narrow bridge to AppKit's semantic vibrancy materials. The system owns
/// the blur, contrast, and light/dark treatment; this view does not draw or
/// cache a custom translucency layer.
struct BrowserVisualEffectView: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    configure(nsView)
  }

  private func configure(_ view: NSVisualEffectView) {
    view.material = material
    view.blendingMode = blendingMode
    view.state = .followsWindowActiveState
    view.isEmphasized = false
  }
}

private struct BrowserTitlebarContentInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var browserTitlebarContentInset: CGFloat {
    get { self[BrowserTitlebarContentInsetKey.self] }
    set { self[BrowserTitlebarContentInsetKey.self] = newValue }
  }
}

extension View {
  /// Native material for the continuous left-side workspace region.
  func browserSidebarMaterial() -> some View {
    background(
      BrowserVisualEffectView(material: .sidebar, blendingMode: .withinWindow)
    )
  }

  /// Native material for the flat browser-header region. It has no capsule or
  /// outer card boundary, so the address capsule remains the visual control.
  func browserToolbarMaterial() -> some View {
    background(
      BrowserVisualEffectView(material: .headerView, blendingMode: .withinWindow)
    )
  }
}
