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
  @StateObject private var browserChromeState = BrowserChromeState()

  var body: some View {
    BrowserWorkspaceView(
      workspace: runtime.workspaceStore,
      titlebarLeadingControlInset: windowChromeState.titlebarLeadingControlInset,
      isSidebarVisible: $browserChromeState.isSidebarVisible
    )
      .frame(minWidth: 900, minHeight: 500)
      .background(Color(nsColor: .windowBackgroundColor))
      .background(
        WindowChromeConfigurator { leadingControlInset in
          guard abs(windowChromeState.titlebarLeadingControlInset - leadingControlInset) > 0.5
          else {
            return
          }
          windowChromeState.titlebarLeadingControlInset = leadingControlInset
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
      )
      .onAppear { runtime.noteMainWindowAppeared() }
      .sheet(item: $runtime.presentedInternalPanel) { panel in
        BrowserLibrarySheet(
          panel: panel,
          history: runtime.historyService,
          downloads: runtime.downloadManager,
          workspace: runtime.workspaceStore)
      }
  }
}

@MainActor
private final class WindowChromeState: ObservableObject {
  @Published var titlebarLeadingControlInset: CGFloat = 0
}

/// Presentation-only shell state. Sidebar visibility is intentionally not part
/// of the workspace/session model and is not persisted across launches.
@MainActor
private final class BrowserChromeState: ObservableObject {
  @Published var isSidebarVisible = true
}

private struct BrowserWorkspaceView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  let titlebarLeadingControlInset: CGFloat
  @Binding var isSidebarVisible: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      HStack(spacing: 0) {
        // Keep the sidebar mounted for the whole presentation-state lifetime.
        // Only its visible width changes, so the live workspace and every CEF
        // session remain untouched while the content column expands.
        TabSidebarView(workspace: workspace)
          .frame(
            width: isSidebarVisible ? BrowserChromeLayout.sidebarWidth : 0,
            alignment: .leading)
          .clipped()
          .allowsHitTesting(isSidebarVisible)
          .accessibilityHidden(!isSidebarVisible)

        BrowserContentColumn(workspace: workspace)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      // The body plane starts below the shared chrome band. The chrome itself
      // is a sibling overlay, so there is no toolbar placeholder in either
      // the sidebar or the browser surface branch.
      .padding(.top, BrowserChromeLayout.toolbarHeight)

      BrowserTopChromeView(
        workspace: workspace,
        isSidebarVisible: $isSidebarVisible,
        titlebarLeadingControlInset: titlebarLeadingControlInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .zIndex(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    // The window is configured as a full-size content view. This lets the
    // shared chrome continue behind the native traffic lights while both
    // scrollable/sidebar and Chromium bodies begin below that band.
    .ignoresSafeArea(.container, edges: [.top, .leading, .bottom])
    .animation(BrowserChromeLayout.sidebarAnimation, value: isSidebarVisible)
  }
}

/// The browser side of the window. The surface host remains a single
/// representable for the whole window and never owns or recreates a Chromium
/// view when the sidebar or selected session changes.
private struct BrowserContentColumn: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    ZStack {
      BrowserSurfaceFrame {
        // The runtime manager retains one container per live session. The
        // workspace store publishes only the effective selected tab; Space
        // switches therefore change visibility without recreating Chromium.
        BrowserSurfaceView(manager: workspace.sessionManager)
      }

      if let session = workspace.selectedSession, session.rendererCrashed {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 28))
            .accessibilityHidden(true)
          Text("This page stopped responding")
            .font(.headline)
          Text("The page process ended unexpectedly. Reload to start it again.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
          Button("Reload") {
            session.reload()
          }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("renderer-crash-reload")
        }
        .padding(28)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page stopped responding")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
  let onTitlebarLeadingControlInsetChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> WindowChromeView {
    WindowChromeView(onTitlebarLeadingControlInsetChange: onTitlebarLeadingControlInsetChange)
  }

  func updateNSView(_ nsView: WindowChromeView, context: Context) {
    nsView.onTitlebarLeadingControlInsetChange = onTitlebarLeadingControlInsetChange
    nsView.configureWindowIfNeeded()
  }
}

private final class WindowChromeView: NSView {
  var onTitlebarLeadingControlInsetChange: (CGFloat) -> Void
  private var lastTitlebarLeadingControlInset: CGFloat?
  private var addressFieldMouseMonitor: Any?
  private var windowObservers: [NSObjectProtocol] = []
  private var isConfiguringWindow = false

  init(onTitlebarLeadingControlInsetChange: @escaping (CGFloat) -> Void) {
    self.onTitlebarLeadingControlInsetChange = onTitlebarLeadingControlInsetChange
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeWindowTransitions()
    configureWindowIfNeeded()

    if addressFieldMouseMonitor == nil, let window {
      addressFieldMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
        [weak window] event in
        guard let window, event.window === window else { return event }
        let location = event.locationInWindow
        let hit = window.contentView?.hitTest(location)
        var candidate = hit
        while let view = candidate {
          if let field = view as? NativeBrowserAddressField {
            // A full-size titled window can route this titlebar-area click
            // through AppKit before the embedded representable receives it.
            // Forward only the hit-tested pointer event to the native field;
            // keyboard events and Cmd-L remain entirely in their normal paths.
            field.mouseDown(with: event)
            return nil
          }
          candidate = view.superview
        }
        return event
      }
    }

    // SwiftUI can attach the representable before AppKit has installed the
    // standard window buttons. Re-measure on the next run-loop turn so the
    // toolbar gets the actual native traffic-light geometry on first display.
    DispatchQueue.main.async { [weak self] in
      self?.configureWindowIfNeeded()
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    removeAddressFieldMouseMonitor()
    removeWindowObservers()
    super.viewWillMove(toWindow: newWindow)
  }

  private func observeWindowTransitions() {
    guard let window, windowObservers.isEmpty else { return }
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didResignMainNotification,
    ]
    windowObservers = names.map { name in
      NotificationCenter.default.addObserver(
        forName: name, object: window, queue: .main
      ) { [weak self] _ in
        self?.configureWindowIfNeeded()
      }
    }
  }

  private func removeWindowObservers() {
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers.removeAll()
  }

  private func removeAddressFieldMouseMonitor() {
    if let addressFieldMouseMonitor {
      NSEvent.removeMonitor(addressFieldMouseMonitor)
      self.addressFieldMouseMonitor = nil
    }
  }

  override func layout() {
    super.layout()
    // Full-screen transitions and live titlebar changes can move the standard
    // buttons. Re-measuring during layout keeps the horizontal exclusion
    // region aligned with native chrome.
    configureWindowIfNeeded()
  }

  func configureWindowIfNeeded() {
    guard let window, !isConfiguringWindow else { return }
    isConfiguringWindow = true
    defer { isConfiguringWindow = false }

    // These are the public AppKit APIs for a titled window whose content is
    // allowed to occupy the titlebar area. In particular, this does not
    // replace the titled window with a borderless custom window.
    var configurationChanged = false
    if !window.styleMask.contains(.fullSizeContentView) {
      window.styleMask.insert(.fullSizeContentView)
      configurationChanged = true
    }
    if !window.titlebarAppearsTransparent {
      window.titlebarAppearsTransparent = true
      configurationChanged = true
    }
    if window.titleVisibility != .hidden {
      window.titleVisibility = .hidden
      configurationChanged = true
    }
    if window.titlebarSeparatorStyle != .none {
      window.titlebarSeparatorStyle = .none
      configurationChanged = true
    }
    // SwiftUI's title-bar scene may install an empty NSToolbar. With no
    // browser items in it, that object only contributes toolbar material.
    if let toolbar = window.toolbar, toolbar.items.isEmpty {
      window.toolbar = nil
      configurationChanged = true
    }

    if configurationChanged {
      // The representable is attached after SwiftUI has created the titled
      // window. Invalidate and immediately settle the view tree so the first
      // measurement and the first chrome frame use the same AppKit geometry.
      window.contentView?.needsLayout = true
      window.contentView?.layoutSubtreeIfNeeded()
    }

    guard let leadingControlInset = measuredTitlebarLeadingControlInset(for: window) else {
      // The standard buttons can be installed by AppKit one layout pass after
      // this representable enters the window. Leave the value uncommitted so
      // the next layout pass can publish the real horizontal exclusion.
      return
    }
    guard lastTitlebarLeadingControlInset != leadingControlInset else { return }
    lastTitlebarLeadingControlInset = leadingControlInset
    onTitlebarLeadingControlInsetChange(leadingControlInset)
  }

  /// Measures the right edge of the actual native traffic-light controls in
  /// the full-size content view's coordinate system. The toolbar uses this as
  /// a horizontal exclusion region; no vertical titlebar value is used for it.
  private func measuredTitlebarLeadingControlInset(for window: NSWindow) -> CGFloat? {
    guard let contentView = window.contentView else { return nil }
    let contentViewFrameInWindow = contentView.convert(contentView.bounds, to: nil)

    let buttonTypes: [NSWindow.ButtonType] = [
      .closeButton,
      .miniaturizeButton,
      .zoomButton,
    ]
    let buttonFrames = buttonTypes.compactMap { type -> NSRect? in
      guard let button = window.standardWindowButton(type) else { return nil }
      // A standard window button lives in AppKit's titlebar hierarchy rather
      // than below the SwiftUI content view. Convert to the window base
      // coordinate system first, then normalize to the content view's origin.
      return button.convert(button.bounds, to: nil)
    }
    guard let rightEdgeInWindow = buttonFrames.map(\.maxX).max() else { return nil }
    let rightEdge = rightEdgeInWindow - contentViewFrameInWindow.minX

    // The visible circles extend beyond their AppKit button frames. Leave a
    // measured-frame inset large enough for 8–10 points of visual clearance.
    let buttonWidth = buttonFrames.map(\.width).min() ?? 0
    let systemSpacing = max(19, min(21, buttonWidth * 1.35))
    return max(0, rightEdge + systemSpacing)
  }
}
