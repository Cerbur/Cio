//
//  MainWindowView.swift
//  NativeBrowser
//
//  The Milestone 5.1 single-window layout: a native Space/tab sidebar, one
//  compact toolbar, and one stable Chromium surface host containing every live
//  session across every Space.
//

import AppKit
import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var runtime: ApplicationRuntime
  @StateObject private var windowChromeState = WindowChromeState()

  var body: some View {
    BrowserWorkspaceView(
      workspace: runtime.workspaceStore,
      titlebarContentInset: windowChromeState.titlebarContentInset
    )
      .frame(minWidth: 900, minHeight: 500)
      .background(Color(nsColor: .windowBackgroundColor))
      .background(
        WindowChromeConfigurator { inset in
          guard abs(windowChromeState.titlebarContentInset - inset) > 0.5 else {
            return
          }
          windowChromeState.titlebarContentInset = inset
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
      )
      .onAppear { runtime.noteMainWindowAppeared() }
  }
}

@MainActor
private final class WindowChromeState: ObservableObject {
  @Published var titlebarContentInset: CGFloat = 0
}

private struct BrowserWorkspaceView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  let titlebarContentInset: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      TabSidebarView(workspace: workspace)
        .environment(\.browserTitlebarContentInset, titlebarContentInset)

      BrowserContentColumn(workspace: workspace)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    // The window is configured as a full-size content view. This lets the
    // sidebar material continue behind the native traffic lights while the
    // sidebar's own content uses the window-provided safe area.
    .ignoresSafeArea(.container, edges: [.top, .leading, .bottom])
  }
}

/// The browser side of the window. The surface host remains a single
/// representable for the whole window; the toolbar is a presentational sibling
/// above it and never owns or recreates a Chromium view.
private struct BrowserContentColumn: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      if let session = workspace.selectedSession {
        BrowserToolbarView(session: session)
          .addressFieldFocusListener(session: session)
      } else {
        Color.clear.frame(height: 46)
      }

      BrowserSurfaceFrame {
        // The runtime manager retains one container per live session. The
        // workspace store publishes only the effective selected tab; Space
        // switches therefore change visibility without recreating Chromium.
        BrowserSurfaceView(manager: workspace.sessionManager)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// The content plane around Chromium. It deliberately has no rounded border,
/// mask, clip, or glass effect: CEF's native child view must remain a stable,
/// unmodified windowed-rendering surface.
private struct BrowserSurfaceFrame<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
  }
}

/// The SwiftUI Window scene keeps the native titled-window behavior, while the
/// content view opts into the AppKit full-size layout. The native traffic
/// lights remain owned by NSWindow; only the title text and titlebar background
/// are made transparent so the sidebar can visually continue behind them.
private struct WindowChromeConfigurator: NSViewRepresentable {
  let onTitlebarContentInsetChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> WindowChromeView {
    WindowChromeView(onTitlebarContentInsetChange: onTitlebarContentInsetChange)
  }

  func updateNSView(_ nsView: WindowChromeView, context: Context) {
    nsView.onTitlebarContentInsetChange = onTitlebarContentInsetChange
    nsView.configureWindowIfNeeded()
  }
}

private final class WindowChromeView: NSView {
  var onTitlebarContentInsetChange: (CGFloat) -> Void
  private var lastTitlebarContentInset: CGFloat?

  init(onTitlebarContentInsetChange: @escaping (CGFloat) -> Void) {
    self.onTitlebarContentInsetChange = onTitlebarContentInsetChange
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWindowIfNeeded()

    // SwiftUI can attach the representable before AppKit has installed the
    // standard window buttons. Re-measure on the next run-loop turn so the
    // sidebar gets the actual native titlebar geometry on first display.
    DispatchQueue.main.async { [weak self] in
      self?.configureWindowIfNeeded()
    }
  }

  override func layout() {
    super.layout()
    // Full-screen transitions and live titlebar changes invalidate the
    // content layout rect. Re-measuring during layout keeps the sidebar's
    // fixed safe spacer aligned with the native window chrome.
    configureWindowIfNeeded()
  }

  func configureWindowIfNeeded() {
    guard let window else { return }

    // These are the public AppKit APIs for a titled window whose content is
    // allowed to occupy the titlebar area. In particular, this does not
    // replace the titled window with a borderless custom window.
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbarStyle = .unifiedCompact

    let inset = measuredTitlebarContentInset(for: window)
    guard lastTitlebarContentInset != inset else { return }
    lastTitlebarContentInset = inset
    onTitlebarContentInsetChange(inset)
  }

  /// Measures the system-provided titlebar geometry instead of assuming a
  /// traffic-light coordinate. The content layout rect is the public AppKit
  /// answer for the part of a full-size window not covered by native chrome;
  /// the standard close button is only a defensive fallback for window styles
  /// that report a zero layout inset while the titlebar is still present.
  private func measuredTitlebarContentInset(for window: NSWindow) -> CGFloat {
    var measurements = [
      window.frame.height - window.contentLayoutRect.maxY,
      window.contentView?.safeAreaInsets.top ?? 0,
    ]

    if let closeButton = window.standardWindowButton(.closeButton) {
      let buttonFrame = closeButton.convert(closeButton.bounds, to: nil)
      measurements.append(window.frame.height - buttonFrame.minY)
    }

    return max(0, measurements.max() ?? 0)
  }
}
