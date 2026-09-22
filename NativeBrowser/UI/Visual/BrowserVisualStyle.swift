//
//  BrowserVisualStyle.swift
//  NativeBrowser
//
//  Presentation-only visual helpers for the Milestone 5 browser chrome.
//
//  The app currently targets macOS 26, where SwiftUI's native Liquid Glass
//  modifier is available. The availability branch keeps this helper safe if
//  the deployment target is lowered later: the fallback is still a semantic
//  semantic regular material and never a hand-built blur or screenshot
//  effect.
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

/// A compact group of related actions that shares one native Liquid Glass
/// surface. The buttons remain separate hit targets while the surrounding
/// capsule reads as one piece of browser chrome.
struct BrowserGlassControlGroup<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(2)
      .browserGlassControlSurface()
  }
}

/// An icon-only control for the compact browser chrome. Hover and pressed
/// feedback live inside the shared group surface instead of creating a glass
/// bubble for every action.
struct BrowserGlassIconButton: View {
  let systemImage: String
  let label: String
  let isEnabled: Bool
  let action: () -> Void
  @StateObject private var interaction = BrowserInteractionState()

  init(
    systemImage: String,
    label: String,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.label = label
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 28, height: 28)
    }
    .buttonStyle(
      BrowserGlassIconButtonStyle(
        isEnabled: isEnabled,
        isHovered: interaction.isHovered)
    )
    .disabled(!isEnabled)
    .onHover { interaction.isHovered = $0 }
    .help(label)
    .accessibilityLabel(label)
  }
}

private struct BrowserGlassIconButtonStyle: ButtonStyle {
  let isEnabled: Bool
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        isEnabled ? Color.primary.opacity(0.88) : Color.primary.opacity(0.34)
      )
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            configuration.isPressed
              ? Color.primary.opacity(0.15)
              : (isHovered && isEnabled ? Color.primary.opacity(0.08) : Color.clear)
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

extension View {
  /// Applies one compact system glass capsule to a related control group.
  /// macOS 26 owns the translucency and interaction treatment; the fallback
  /// remains a semantic system material for lower deployment targets.
  @ViewBuilder
  func browserGlassControlSurface() -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: Capsule())
    } else {
      background(.regularMaterial, in: Capsule())
    }
  }

  /// Gives the address field a compact native control surface without turning
  /// the toolbar into a second glass card. Clear Liquid Glass stays decorative
  /// and the semantic fill adapts to the system appearance; the embedded
  /// NSTextField remains the hit target.
  @ViewBuilder
  func browserAddressFieldSurface(isFocused: Bool, cornerRadius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let surface = background {
      shape
        .fill(
          Color(nsColor: .controlBackgroundColor)
            .opacity(isFocused ? 0.78 : 0.54)
        )
        .allowsHitTesting(false)
    }

    if #available(macOS 26.0, *) {
      surface.background {
        Color.clear
          .glassEffect(.clear, in: shape)
          .allowsHitTesting(false)
      }
    } else {
      surface.background(.regularMaterial, in: shape)
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
        .allowsHitTesting(false)
    )
  }

  /// Native material for the flat browser-header region. It has no capsule or
  /// outer card boundary, so the address capsule remains the visual control.
  func browserToolbarMaterial() -> some View {
    background(
      BrowserVisualEffectView(material: .headerView, blendingMode: .withinWindow)
        .allowsHitTesting(false)
    )
  }
}
