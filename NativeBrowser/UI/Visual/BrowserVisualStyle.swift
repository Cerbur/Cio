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

import SwiftUI

/// Ephemeral presentation state shared by the small hover/focus surfaces. It
/// never mirrors tab selection, browser sessions or navigation state.
@MainActor
final class BrowserInteractionState: ObservableObject {
  @Published var isHovered = false
  @Published var isFocused = false
}

extension View {
  /// Applies the system Liquid Glass treatment to browser chrome.
  ///
  /// Glass is intentionally used only by the sidebar and toolbar surfaces.
  /// Chromium content is never passed through this modifier, so the native
  /// CEF child view keeps its normal windowed-rendering and hit-test behavior.
  @ViewBuilder
  func browserGlass(cornerRadius: CGFloat) -> some View {
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
