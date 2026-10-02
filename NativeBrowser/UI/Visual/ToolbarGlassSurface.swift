import AppKit
import SwiftUI

/// Shared by the toolbar's separate hosts so every glass surface transitions
/// together while native controls and the address editor stay mounted.
@MainActor
final class ToolbarPresentationState: ObservableObject {
  @Published private(set) var isVisible = true

  func setVisible(_ visible: Bool, animated: Bool) {
    guard isVisible != visible else { return }
    let animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var transaction = Transaction(animation: animates ? .smooth(duration: 0.25) : nil)
    transaction.disablesAnimations = !animates
    withTransaction(transaction) { isVisible = visible }
  }
}

/// Only the glass enters and leaves the hierarchy. Keeping its container alive
/// lets SwiftUI finish the native materialize transition in both directions.
struct ToolbarGlassSurface: View {
  @ObservedObject var presentation: ToolbarPresentationState
  let cornerRadius: CGFloat
  var isInteractive = false
  @Namespace private var glassNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassEffectContainer(spacing: 0) {
      if presentation.isVisible {
        Color.clear
          .glassEffect(isInteractive ? .regular.interactive() : .regular,
                       in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
          .glassEffectID("surface", in: glassNamespace)
          .glassEffectTransition(reduceMotion ? .identity : .materialize)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// AppKit buttons retain their native tracking and toolbar bezel. Their content
/// fades independently of the material's own transition.
struct ToolbarGlassControlView: View {
  let content: NSView
  @ObservedObject var presentation: ToolbarPresentationState
  let size: NSSize

  var body: some View {
    ToolbarNativeControl(view: content)
      .frame(width: size.width, height: size.height)
      .opacity(presentation.isVisible ? 1 : 0)
      .background {
        ToolbarGlassSurface(presentation: presentation,
                            cornerRadius: size.height / 2, isInteractive: true)
      }
      .allowsHitTesting(presentation.isVisible)
      .accessibilityHidden(!presentation.isVisible)
  }
}

private struct ToolbarNativeControl: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ view: NSView, context: Context) {}
}
