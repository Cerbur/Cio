import AppKit
import SwiftUI

/// A nonactivating, click-through hint. Keep its transparent host alive until
/// the shared native materialize transition finishes in both directions.
@MainActor
public final class BrowserFullscreenDisclosure {
  // All Cio tabs share a native window. Browser and webpage fullscreen requests
  // must produce one hint for that window, including after its timer expires.
  private static let presentedWindows = NSHashTable<NSWindow>.weakObjects()
  private static let fullscreenExitObservation = NotificationCenter.default.addObserver(
    forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { notification in
      let window = notification.object as? NSWindow
      MainActor.assumeIsolated {
        if let window {
          presentedWindows.remove(window)
        }
      }
    }
  private var panel: NSPanel?
  private weak var parent: NSWindow?
  private var presentation: ToolbarPresentationState?
  private var dismissal: DispatchWorkItem?
  private var retirement: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []
  private var generation = UUID()
  private var drawingOutset: CGFloat = 0

  public init() {}

  @discardableResult
  public func show(in parent: NSWindow, completion: @escaping () -> Void) -> Bool {
    _ = Self.fullscreenExitObservation
    guard !Self.presentedWindows.contains(parent) else { return false }
    Self.presentedWindows.add(parent)
    dismiss()
    self.parent = parent
    let token = generation
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let visibilityDuration = AnimationValues.FullscreenDisclosure.visibilityDuration
    let retirementDuration = reduceMotion ? 0 : AnimationValues.FullscreenDisclosure.retirementDuration
    let label = "按 Esc 退出全屏"
    let textWidth = (label as NSString).size(withAttributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium)
    ]).width
    let width = max(1, min(ceil(textWidth) + 28, 420, parent.frame.width - 64))
    drawingOutset = AnimationValues.FullscreenDisclosure.drawingOutset(for: CGSize(width: width, height: 36))
    let presentation = ToolbarPresentationState()
    presentation.setVisible(false, animated: false)
    self.presentation = presentation
    let host = NSHostingView(rootView: FullscreenDisclosureContent(
      label: label, width: width, presentation: presentation))
    host.safeAreaRegions = []
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width + drawingOutset * 2,
                                          height: 36 + drawingOutset * 2),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.appearance = parent.appearance
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.contentView = host
    self.panel = panel
    positionPanel()
    for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                 NSWindow.didEnterFullScreenNotification, NSWindow.didChangeScreenNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.positionPanel() }
      })
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.dismiss() }
      })
    parent.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    host.layoutSubtreeIfNeeded()
    presentation.setVisible(true, animated: true)

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.dismissal = nil
      presentation.setVisible(false, animated: true, animation: .smooth(duration: visibilityDuration))
      let cleanup = DispatchWorkItem { [weak self] in
        guard let self, self.generation == token else { return }
        self.dismiss()
        completion()
      }
      self.retirement = cleanup
      DispatchQueue.main.asyncAfter(deadline: .now() + retirementDuration, execute: cleanup)
    }
    dismissal = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + AnimationValues.FullscreenDisclosure.holdDuration, execute: work)
    return true
  }

  /// Explicit exit/navigation/close cancels both clocks and the timeout callback.
  public func dismiss() {
    generation = UUID()
    dismissal?.cancel()
    retirement?.cancel()
    dismissal = nil
    retirement = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    presentation?.setVisible(false, animated: false)
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      panel.close()
    }
    panel = nil
    parent = nil
    presentation = nil
  }

  private func positionPanel() {
    guard let panel, let parent else { return }
    panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                 y: parent.frame.maxY - 32 + drawingOutset - panel.frame.height))
  }
}

private struct FullscreenDisclosureContent: View {
  let label: String
  let width: CGFloat
  @ObservedObject var presentation: ToolbarPresentationState

  var body: some View {
    Text(label)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, 14)
      .frame(width: width, height: 36)
      .modifier(GlassComponentContentVisibility(isVisible: presentation.isVisible))
      .background {
        ToolbarGlassSurface(presentation: presentation, cornerRadius: BrowserLayout.contentCornerRadius)
      }
      .modifier(GlassComponentVisibility(isVisible: presentation.isVisible))
      .accessibilityHidden(!presentation.isVisible)
      .accessibilityIdentifier("fullscreen-disclosure")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)
  }
}
