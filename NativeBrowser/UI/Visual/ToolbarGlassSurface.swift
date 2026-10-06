import AppKit
import SwiftUI

/// Shared first-level contract: native materialize owns glass insertion/removal;
/// content resolves blur/opacity, and the whole component converges/disperses.
/// Layout motion is independent so surviving controls move without disappearing.
struct ToolbarComponentVisibility: ViewModifier {
  @ObservedObject var presentation: ToolbarPresentationState

  func body(content: Content) -> some View {
    content.modifier(GlassComponentVisibility(isVisible: presentation.isVisible))
      .allowsHitTesting(presentation.isVisible)
      .accessibilityHidden(!presentation.isVisible)
  }
}

/// Shared by the toolbar's separate hosts so every glass surface transitions
/// together while native controls and the address editor stay mounted.
@MainActor
final class ToolbarPresentationState: ObservableObject {
  @Published private(set) var isVisible = true
  private var requestedVisible = true
  private var appearanceToken: UUID?

  func setVisible(_ visible: Bool, animated: Bool, animation: Animation? = nil) {
    guard requestedVisible != visible else { return }
    requestedVisible = visible
    appearanceToken = nil
    let animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let duration = AnimationValues.Toolbar.visibilityDuration
    let update = { [weak self] in
      guard let self else { return }
      var transaction = Transaction(animation: animates ? (animation ?? .smooth(duration: duration)) : nil)
      transaction.disablesAnimations = !animates
      withTransaction(transaction) { self.isVisible = visible }
    }
    if visible && animates && animation == nil {
      // Newly mounted SwiftUI hosts must commit their hidden tree before the
      // insertion transaction. This is a render handoff, not an animation delay.
      let token = UUID()
      appearanceToken = token
      DispatchQueue.main.async { [weak self] in
        guard let self, self.appearanceToken == token, self.requestedVisible else { return }
        self.appearanceToken = nil
        update()
      }
    } else {
      // Page-owned reveals have already mounted and laid out the hidden hosts.
      // Join their transaction now; another main-queue hop would offset chrome.
      update()
    }
  }
}

/// Only the glass enters and leaves the hierarchy. Keeping its container alive
/// lets SwiftUI finish the native materialize transition in both directions.
struct ToolbarGlassSurface: View {
  @ObservedObject var presentation: ToolbarPresentationState
  let cornerRadius: CGFloat
  var interactive = false
  @Namespace private var glassNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassEffectContainer(spacing: 0) {
      if presentation.isVisible {
        Color.clear
          .glassEffect(.regular.interactive(interactive),
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

/// Keep native AppKit buttons mounted over one SwiftUI-owned native glass
/// surface, so all three toolbar components can use the same materialize API.
struct ToolbarNativeControlsView: View {
  let content: NSView
  @ObservedObject var presentation: ToolbarPresentationState
  let size: NSSize

  var body: some View {
    ToolbarNativeControl(view: content)
      .frame(width: size.width, height: size.height)
      .modifier(GlassComponentContentVisibility(isVisible: presentation.isVisible))
      .background {
        // Interaction belongs to the native glass buttons above this surface.
        // A hit-test-disabled SwiftUI background cannot own their press state.
        ToolbarGlassSurface(presentation: presentation, cornerRadius: size.height / 2)
      }
      .modifier(ToolbarComponentVisibility(presentation: presentation))
  }
}

private struct ToolbarNativeControl: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ view: NSView, context: Context) {}
}
