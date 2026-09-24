//
//  BrowserVisualStyle.swift
//  NativeBrowser
//
//  Presentation-only visual helpers for the Milestone 5 browser chrome.
//
//  The app targets macOS 26 for native Liquid Glass controls. The address
//  surface keeps a semantic material fallback if that target is lowered.
//

import AppKit
import SwiftUI

/// Shared geometry for the one browser chrome band. The shell body and the
/// top-chrome overlay use these values so collapsing the sidebar never changes
/// the page's vertical origin.
enum BrowserChromeLayout {
  static let toolbarHeight: CGFloat = 44
  static let chromeControlHeight: CGFloat = 36
  static let chromeSymbolSize: CGFloat = 15
  static let chromeGlassButtonStackSpacing: CGFloat = 0
  static let chromeGlassContainerSpacing: CGFloat = 24
  static let addressGlobeSymbolSize: CGFloat = 14
  static let addressFieldCornerRadius: CGFloat = chromeControlHeight / 2
  static let sidebarWidth: CGFloat = 248
  static let chromeEdgeInset: CGFloat = (toolbarHeight - chromeControlHeight) / 2
  static let sidebarToggleToNav: CGFloat = 6
  static let navToAddress: CGFloat = 10
  static let chromeTrailingPadding: CGFloat = 10
  static let chromeVerticalPadding: CGFloat = chromeEdgeInset
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

extension View {
  /// Applies the system glass surface used by browser chrome.
  @ViewBuilder
  func browserChromeGlassSurface<S: Shape>(in shape: S) -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: shape)
    } else {
      background(.regularMaterial, in: shape)
    }
  }

  /// Gives the address field the same decorative chrome glass as navigation.
  /// The embedded NSTextField remains the hit target.
  @ViewBuilder
  func browserAddressFieldSurface(cornerRadius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    background {
      Color.clear
        .browserChromeGlassSurface(in: shape)
        .allowsHitTesting(false)
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
