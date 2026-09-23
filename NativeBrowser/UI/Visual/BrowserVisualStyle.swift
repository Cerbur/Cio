//
//  BrowserVisualStyle.swift
//  NativeBrowser
//
//  Presentation-only visual helpers for the Milestone 5 browser chrome.
//
//  The app targets macOS 26 for native Liquid Glass buttons. The address
//  surface keeps a semantic material fallback if that target is lowered.
//

import AppKit
import SwiftUI

/// Shared geometry for the one browser chrome band. The shell body and the
/// top-chrome overlay use these values so collapsing the sidebar never changes
/// the page's vertical origin.
enum BrowserChromeLayout {
  static let toolbarHeight: CGFloat = 44
  static let sidebarWidth: CGFloat = 248
  static let iconHitTarget: CGFloat = 28
  static let glassOuterPadding: CGFloat = 2
  static let glassInnerSpacing: CGFloat = 1
  static let sidebarToggleToNav: CGFloat = 6
  static let navToAddress: CGFloat = 10
  static let chromeTrailingPadding: CGFloat = 10
  static let chromeVerticalPadding: CGFloat = 6
  static let expandedNavigationLeadingPadding: CGFloat = 10
  static let sidebarAnimation = Animation.easeInOut(duration: 0.22)
}

/// Ephemeral presentation state shared by the hover and focus surfaces. It
/// never mirrors tab selection, browser sessions or navigation state.
@MainActor
final class BrowserInteractionState: ObservableObject {
  @Published var isHovered = false
  @Published var isFocused = false
}

/// Related native glass buttons compose into a compact control group.
struct BrowserGlassControlGroup<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(spacing: BrowserChromeLayout.glassInnerSpacing) {
      content
    }
    .padding(BrowserChromeLayout.glassOuterPadding)
    .browserGlassControlSurface()
  }
}

/// A single icon control that owns one native Liquid Glass surface. It is
/// used for the collapsed Show Sidebar affordance, which has no sibling with
/// which to form a navigation cluster.
struct BrowserGlassStandaloneIconButton: View {
  let systemImage: String
  let label: String
  let isEnabled: Bool
  let action: () -> Void

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
    BrowserGlassControlGroup {
      BrowserGlassIconButton(
        systemImage: systemImage,
        label: label,
        isEnabled: isEnabled,
        action: action)
    }
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
        .frame(
          width: BrowserChromeLayout.iconHitTarget,
          height: BrowserChromeLayout.iconHitTarget)
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
        isEnabled
          ? Color.primary.opacity(configuration.isPressed ? 0.98 : (isHovered ? 0.96 : 0.88))
          : Color.primary.opacity(0.34)
      )
  }
}

extension View {
  /// Applies one compact system glass capsule to a related control group.
  /// The buttons remain independent hit targets inside this shared surface.
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

extension View {
  /// Native material for the continuous left-side workspace region.
  func browserSidebarMaterial() -> some View {
    background(
      BrowserVisualEffectView(material: .sidebar, blendingMode: .withinWindow)
        .allowsHitTesting(false)
    )
  }
}
