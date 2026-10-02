import AppKit
import SwiftUI

/// USER-REQUIRED TOOLBAR ANIMATION CONTRACT:
/// Apply once to each first-level component (sidebar button, shared Back/Forward
/// capsule, address capsule), including its native glass and content. Insertion
/// fades from an enlarged, dispersed state into its resting size; removal fades
/// while enlarging outward from the same centre. Never use a directional slide
/// for visibility. Symbols, text, reload controls and other capsule children keep
/// their own interaction animations; do not apply this contract recursively.
/// Window-owned traffic lights stay mounted and retain their native behaviour.
/// Switching one single-page tab to another replaces the existing toolbar slot
/// immediately, without visibility animation. Split entry/exit and section
/// visibility changes still use this contract; surviving controls only reflow.
///
/// Apple recommends materialize for independent glass insertion/removal and
/// permits custom transitions alongside it:
/// https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
/// The scale and duration below implement our motion direction, not an Apple
/// prescribed numeric specification. AppKit buttons retain their own glass;
/// SwiftUI address glass uses the native materialize transition as well.
enum ToolbarComponentAnimation {
  static let duration: TimeInterval = 0.25
  static let dispersedScale: CGFloat = 1.12
}

/// Keep the native control/editor mounted so focus and native interaction state
/// survive visibility changes. Scale the complete component around its centre,
/// independently of layout; reduced motion uses opacity only.
struct ToolbarComponentVisibility: ViewModifier {
  @ObservedObject var presentation: ToolbarPresentationState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .scaleEffect(presentation.isVisible || reduceMotion ? 1 : ToolbarComponentAnimation.dispersedScale)
      .opacity(presentation.isVisible ? 1 : 0)
      .allowsHitTesting(presentation.isVisible)
      .accessibilityHidden(!presentation.isVisible)
  }
}

/// Shared by the toolbar's separate hosts so every glass surface transitions
/// together while native controls and the address editor stay mounted.
@MainActor
final class ToolbarPresentationState: ObservableObject {
  @Published private(set) var isVisible = true

  func setVisible(_ visible: Bool, animated: Bool) {
    guard isVisible != visible else { return }
    let animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var transaction = Transaction(animation: animates ? .smooth(duration: ToolbarComponentAnimation.duration) : nil)
    transaction.disablesAnimations = !animates
    withTransaction(transaction) { isVisible = visible }
  }
}

/// Only the glass enters and leaves the hierarchy. Keeping its container alive
/// lets SwiftUI finish the native materialize transition in both directions.
struct ToolbarGlassSurface: View {
  @ObservedObject var presentation: ToolbarPresentationState
  let cornerRadius: CGFloat
  @Namespace private var glassNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassEffectContainer(spacing: 0) {
      if presentation.isVisible {
        Color.clear
          .glassEffect(.regular,
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

/// Whole-component visibility: standalone AppKit glass buttons and NSGlassEffectView
/// groups own their material and interaction feedback inside the native tree.
struct ToolbarNativeControlsView: View {
  let content: NSView
  @ObservedObject var presentation: ToolbarPresentationState
  let size: NSSize

  var body: some View {
    ToolbarNativeControl(view: content)
      .frame(width: size.width, height: size.height)
      .modifier(ToolbarComponentVisibility(presentation: presentation))
  }
}

private struct ToolbarNativeControl: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ view: NSView, context: Context) {}
}
