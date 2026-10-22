//
//  BrowserVisualStyle.swift
//  Cio
//
//  Presentation-only visual helpers for the Milestone 5 browser chrome.
//
//  The app targets macOS 26 for native Liquid Glass controls. The address
//  surface keeps a semantic material fallback if that target is lowered.
//

import AppKit
import SwiftUI

/// The window-wide, highly translucent glass underneath the shell.
struct GlassBackdrop: View {
  @ObservedObject private var themes = BrowserThemePreferences.shared
  var body: some View {
    WindowBackdropEffect(theme: themes.shell).allowsHitTesting(false)
  }
}

/// Mixed sidebars share the shell's Clear glass instead of stacking a fixed
/// regular material on top of the clarity slider.
struct SidebarGlass: View {
  var theme: SpaceTheme
  var previewShell: ShellTheme? = nil
  @ObservedObject private var themes = BrowserThemePreferences.shared
  @Environment(\.colorScheme) private var colorScheme

  private var localBackdrop: ShellTheme? {
    let backdrop = theme.component(.sidebar).backdrop
    return backdrop.colorMix == nil ? nil : backdrop
  }

  var body: some View {
    Group {
      if let previewShell {
        preview(shell: previewShell)
      } else if let localBackdrop {
        SidebarBackdropRegion(theme: localBackdrop)
      } else if themes.shell.colorMix != nil {
        // Inherit the one shared window backdrop, including its paint.
        Color.clear
      } else {
        legacySurface
      }
    }
    .environment(\.colorScheme, theme.sidebarAppearance.scheme ?? colorScheme)
    .allowsHitTesting(false)
  }

  @ViewBuilder private func preview(shell: ShellTheme) -> some View {
    if let local = localBackdrop {
      WindowBackdropEffect(theme: withinWindow(local))
    } else {
      ZStack {
        WindowBackdropEffect(theme: shell)
        if shell.colorMix == nil { legacySurface }
      }
    }
  }

  private func withinWindow(_ theme: ShellTheme) -> ShellTheme {
    var preview = theme
    preview.blending = .withinWindow
    return preview
  }

  private var legacySurface: some View {
    ZStack {
      switch theme.sidebarGlassSurface {
      case .frosted, .colorMix:
        Rectangle().fill(theme.sidebarMaterial.material).opacity(theme.sidebarOpacity)
      case .liquid:
        Color.clear.glassEffect(theme.component(.sidebar).glass(), in: Rectangle())
          .modifier(ComponentGlassAppearance(theme: theme.component(.sidebar)))
          .opacity(theme.sidebarOpacity)
      case .transparent:
        Color.clear
      }
      theme.sidebarColor.color.opacity(theme.sidebarColorOpacity)
    }
  }
}

struct WindowBackdropEffect: NSViewRepresentable {
  let theme: ShellTheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  func makeNSView(context: Context) -> ThemeBackdropView { ThemeBackdropView() }
  func updateNSView(_ view: ThemeBackdropView, context: Context) {
    view.apply(theme, reduceTransparency: reduceTransparency)
  }
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
  func browserChromeGlassSurface<S: Shape>(in shape: S, component: ThemeComponent = .tab) -> some View {
    if #available(macOS 26.0, *) {
      modifier(ThemedGlassSurface(shape: shape, component: component))
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
        .browserChromeGlassSurface(in: shape, component: .addressBar)
        .allowsHitTesting(false)
    }
  }
}

private struct ThemedGlassSurface<S: Shape>: ViewModifier {
  @Environment(\.browserSpaceTheme) private var spaceTheme
  let shape: S
  let component: ThemeComponent
  @ObservedObject private var themes = BrowserThemePreferences.shared
  func body(content: Content) -> some View {
    content.glassEffect((spaceTheme ?? themes.active).component(component).glass(), in: shape)
      .modifier(ComponentGlassAppearance(theme: (spaceTheme ?? themes.active).component(component)))
  }
}
