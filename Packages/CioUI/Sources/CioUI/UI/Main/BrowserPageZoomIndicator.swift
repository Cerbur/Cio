import AppKit
import SwiftUI

/// One retained host per page. Only the native glass material enters/leaves;
/// repeated zoom changes update the number and renew the idle deadline.
public final class BrowserPageZoomIndicator: NSView {
  public static let hostSize = NSSize(width: 112, height: 68)
  private let state = PageZoomIndicatorState()
  private var host: NSHostingView<PageZoomIndicatorContent>!

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    host = NSHostingView(rootView: PageZoomIndicatorContent(
      state: state, presentation: state.presentation))
    host.safeAreaRegions = []
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  public func show(percent: Int) { state.show(percent: percent) }
  public func dismiss() { state.dismiss() }

  /// Feedback must never steal the page's keyboard or intercept its pointer.
  public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class PageZoomIndicatorState: ObservableObject {
  @Published private(set) var percent = 100
  let presentation = ToolbarPresentationState()
  private var dismissal: DispatchWorkItem?
  private var generation = UUID()

  init() { presentation.setVisible(false, animated: false) }

  func show(percent: Int) {
    dismissal?.cancel()
    generation = UUID()
    let token = generation
    // Changing digits must not restart materialize or animate the host's bounds.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { self.percent = percent }
    presentation.setVisible(true, animated: true)
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.dismissal = nil
      self.presentation.setVisible(false, animated: true)
    }
    dismissal = work
    DispatchQueue.main.asyncAfter(deadline: .now() + AnimationValues.PageZoom.idleDuration, execute: work)
  }

  func dismiss() {
    generation = UUID()
    dismissal?.cancel()
    dismissal = nil
    presentation.setVisible(false, animated: false)
  }
}

private struct PageZoomIndicatorContent: View {
  @ObservedObject var state: PageZoomIndicatorState
  @ObservedObject var presentation: ToolbarPresentationState

  var body: some View {
    Text("\(state.percent)%")
      .font(.system(size: 14, weight: .medium).monospacedDigit())
      .foregroundStyle(.primary)
      .frame(width: 80, height: 36)
      .modifier(GlassComponentContentVisibility(isVisible: presentation.isVisible))
      .background {
        ToolbarGlassSurface(presentation: presentation, cornerRadius: BrowserLayout.contentCornerRadius, component: .zoomIndicator)
      }
      .modifier(GlassComponentVisibility(isVisible: presentation.isVisible))
      .accessibilityLabel("Page zoom")
      .accessibilityValue("\(state.percent)%")
      .accessibilityIdentifier("page-zoom-indicator")
      .accessibilityHidden(!presentation.isVisible)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)
  }
}
