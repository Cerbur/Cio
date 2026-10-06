import AppKit
import SwiftUI

@MainActor
final class ToolbarNavigationState: ObservableObject {
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false

  func update(canGoBack: Bool, canGoForward: Bool) {
    if self.canGoBack != canGoBack { self.canGoBack = canGoBack }
    if self.canGoForward != canGoForward { self.canGoForward = canGoForward }
  }
}

/// One material owns the complete capsule. The stable AppKit container owns
/// its two independent native buttons and keeps them in one responder chain.
struct ToolbarNavigationControlsView: View {
  @ObservedObject var state: ToolbarNavigationState
  @ObservedObject var presentation: ToolbarPresentationState
  let onBack: () -> Void
  let onForward: () -> Void
  @Namespace private var glassNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassEffectContainer(spacing: 0) {
      ToolbarNavigationButtons(canGoBack: state.canGoBack, canGoForward: state.canGoForward,
                               onBack: onBack, onForward: onForward)
        .frame(width: 2 * BrowserLayout.chromeControlSize, height: BrowserLayout.chromeControlSize)
        .modifier(GlassComponentContentVisibility(isVisible: presentation.isVisible))
        .glassEffect(presentation.isVisible ? .regular.interactive() : .identity, in: Capsule())
        .glassEffectID("navigation", in: glassNamespace)
        .glassEffectTransition(reduceMotion ? .identity : .materialize)
    }
    .padding(.horizontal, BrowserLayout.navigationCapsuleEndInset)
    .frame(width: BrowserLayout.navigationCapsuleWidth, height: BrowserLayout.chromeControlSize)
    .modifier(ToolbarComponentVisibility(presentation: presentation))
  }
}

private struct ToolbarNavigationButtons: NSViewRepresentable {
  let canGoBack: Bool
  let canGoForward: Bool
  let onBack: () -> Void
  let onForward: () -> Void

  func makeNSView(context: Context) -> NavigationButtonsView { NavigationButtonsView() }

  func updateNSView(_ view: NavigationButtonsView, context: Context) {
    view.back.isEnabled = canGoBack
    view.forward.isEnabled = canGoForward
    view.onBack = onBack
    view.onForward = onForward
  }
}

private final class NavigationButtonsView: NSView {
  let back = NavigationButtonsView.button("Back", symbol: "chevron.backward")
  let forward = NavigationButtonsView.button("Forward", symbol: "chevron.forward")
  var onBack: (() -> Void)?
  var onForward: (() -> Void)?

  init() {
    super.init(frame: .zero)
    for button in [back, forward] {
      button.target = self
      button.action = #selector(navigate(_:))
      addSubview(button)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layout() {
    super.layout()
    let size = BrowserLayout.chromeControlSize
    back.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
    forward.frame = back.frame.offsetBy(dx: size, dy: 0)
  }

  @objc private func navigate(_ sender: NSButton) {
    if sender === back { onBack?() } else { onForward?() }
  }

  private static func button(_ label: String, symbol: String) -> NSButton {
    let button = NSButton(frame: .zero)
    button.setButtonType(.momentaryPushIn)
    button.bezelStyle = .glass
    button.borderShape = .circle
    button.controlSize = .large
    // The group supplies its sole material. A bordered bezel here would draw
    // a second independent glass circle over each half of that capsule.
    button.isBordered = false
    button.title = ""
    button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    button.toolTip = label
    button.setAccessibilityLabel(label)
    return button
  }
}
