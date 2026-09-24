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

/// Shared geometry for the native AppKit sidebar and its SwiftUI content.
enum BrowserLayout {
  static let sidebarWidth: CGFloat = 248
}

/// Ephemeral presentation state shared by the hover and focus surfaces. It
/// never mirrors tab selection, browser sessions or navigation state.
@MainActor
final class BrowserInteractionState: ObservableObject {
  @Published var isHovered = false
  @Published var isFocused = false
}

extension View {
  /// Applies a single system glass surface to the address control.
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
