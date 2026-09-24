//
//  MainWindowView.swift
//  NativeBrowser
//
//  The Milestone 5.1 single-window layout: a native Space/tab sidebar, one
//  compact toolbar, and one stable Chromium surface host containing every live
//  session across every Space.
//

import AppKit
import OSLog
import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var runtime: ApplicationRuntime
  @StateObject private var windowChromeState = WindowChromeState()
  @StateObject private var browserChromeState = BrowserChromeState()

  var body: some View {
    BrowserWorkspaceView(
      workspace: runtime.workspaceStore,
      titlebarLeadingControlInset: windowChromeState.titlebarLeadingControlInset,
      isFullScreen: windowChromeState.isFullScreen,
      isSidebarVisible: $browserChromeState.isSidebarVisible
    )
      .frame(minWidth: 900, minHeight: 500)
      .background(Color(nsColor: .windowBackgroundColor))
      .background(
        WindowChromeConfigurator(
          onTitlebarLeadingControlInsetChange: { leadingControlInset in
            guard abs(windowChromeState.titlebarLeadingControlInset - leadingControlInset) > 0.5
            else {
              return
            }
            windowChromeState.titlebarLeadingControlInset = leadingControlInset
          },
          onFullScreenChange: { isFullScreen in
            guard windowChromeState.isFullScreen != isFullScreen else { return }
            windowChromeState.isFullScreen = isFullScreen
          })
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
  @Published var isFullScreen = false
}

/// Presentation-only shell state. Sidebar visibility is intentionally not part
/// of the workspace/session model and is not persisted across launches.
@MainActor
private final class BrowserChromeState: ObservableObject {
  @Published var isSidebarVisible = true
}

private struct BrowserWorkspaceView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var workspace: BrowserWorkspaceStore
  let titlebarLeadingControlInset: CGFloat
  let isFullScreen: Bool
  @Binding var isSidebarVisible: Bool

  var body: some View {
    HStack(spacing: 0) {
      // Keep the sidebar mounted while it contracts to zero. Its chrome and
      // body share one material-backed column, including during animation.
      SidebarColumn(
        workspace: workspace,
        isSidebarVisible: isSidebarVisible,
        onHideSidebar: {
          // Let AppKit finish the native button's mouse-up cycle before its
          // glass host leaves the tree and the sidebar begins contracting.
          DispatchQueue.main.async {
            isSidebarVisible = false
          }
        })
        .frame(
          width: isSidebarVisible ? BrowserChromeLayout.sidebarWidth : 0,
          alignment: .leading)
        .clipped()
        .allowsHitTesting(isSidebarVisible)
        .accessibilityHidden(!isSidebarVisible)

      ZStack(alignment: .top) {
        BrowserSurfaceView(manager: workspace.sessionManager)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        VStack(spacing: 0) {
          BrowserTopChromeView(
            workspace: workspace,
            isSidebarVisible: $isSidebarVisible,
            titlebarLeadingControlInset: titlebarLeadingControlInset,
            isFullScreen: isFullScreen)

          BrowserContentColumn(workspace: workspace)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .ignoresSafeArea(.container, edges: [.top, .leading, .bottom])
    .animation(
      reduceMotion ? .easeOut(duration: 0.1) : BrowserChromeLayout.sidebarAnimation,
      value: isSidebarVisible)
  }
}

private struct SidebarColumn: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  let isSidebarVisible: Bool
  let onHideSidebar: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        if isSidebarVisible {
          NativeGlassButtonGroup(
            buttons: [
              NativeChromeButton(
                systemImage: "plus.square.on.square",
                accessibilityLabel: "New Tab",
                isEnabled: true),
              NativeChromeButton(
                systemImage: "sidebar.left",
                accessibilityLabel: "Hide Sidebar",
                isEnabled: true),
            ],
            height: BrowserChromeLayout.chromeControlHeight
          ) { index in
            switch index {
            case 0:
              workspace.createTab(url: nil)
            case 1:
              onHideSidebar()
            default:
              break
            }
          }
          .frame(
            width: BrowserChromeLayout.chromeControlHeight * 2,
            height: BrowserChromeLayout.chromeControlHeight)
          .padding(.trailing, BrowserChromeLayout.chromeTrailingPadding)
        }
      }
      .frame(width: BrowserChromeLayout.sidebarWidth, height: BrowserChromeLayout.toolbarHeight)

      TabSidebarView(workspace: workspace)
        .frame(maxHeight: .infinity)
    }
    .frame(width: BrowserChromeLayout.sidebarWidth)
    .frame(maxHeight: .infinity)
    .browserSidebarMaterial()
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color.primary.opacity(0.12))
        .frame(width: 0.5)
        .allowsHitTesting(false)
    }
  }
}

/// The browser side of the window. The surface host remains a single
/// representable for the whole window and never owns or recreates a Chromium
/// view when the sidebar or selected session changes.
private struct BrowserContentColumn: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    ZStack {
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

/// The SwiftUI Window scene keeps the native titled-window behavior, while the
/// content view opts into the AppKit full-size layout. NSWindow continues to
/// own the traffic lights; their native button views are repositioned together
/// to align with the 44-point chrome geometry.
private struct WindowChromeConfigurator: NSViewRepresentable {
  let onTitlebarLeadingControlInsetChange: (CGFloat) -> Void
  let onFullScreenChange: (Bool) -> Void

  func makeNSView(context: Context) -> WindowChromeView {
    WindowChromeView(
      onTitlebarLeadingControlInsetChange: onTitlebarLeadingControlInsetChange,
      onFullScreenChange: onFullScreenChange)
  }

  func updateNSView(_ nsView: WindowChromeView, context: Context) {
    nsView.onTitlebarLeadingControlInsetChange = onTitlebarLeadingControlInsetChange
    nsView.onFullScreenChange = onFullScreenChange
    nsView.configureWindowIfNeeded()
  }
}

private final class WindowChromeView: NSView {
  var onTitlebarLeadingControlInsetChange: (CGFloat) -> Void
  var onFullScreenChange: (Bool) -> Void
  private var lastTitlebarLeadingControlInset: CGFloat?
  private var lastIsFullScreen: Bool?
  private var addressFieldMouseMonitor: Any?
  private var windowObservers: [NSObjectProtocol] = []
  private var isConfiguringWindow = false
  private var trafficLightHorizontalOffsets: [CGFloat]?
  private var didLogTrafficLightGeometry = false

  init(
    onTitlebarLeadingControlInsetChange: @escaping (CGFloat) -> Void,
    onFullScreenChange: @escaping (Bool) -> Void
  ) {
    self.onTitlebarLeadingControlInsetChange = onTitlebarLeadingControlInsetChange
    self.onFullScreenChange = onFullScreenChange
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
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    windowObservers = names.map { name in
      NotificationCenter.default.addObserver(
        forName: name, object: window, queue: .main
      ) { [weak self] _ in
        DispatchQueue.main.async { [weak self] in
          self?.configureWindowIfNeeded()
        }
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

    let isFullScreen = window.styleMask.contains(.fullScreen)
    if lastIsFullScreen != isFullScreen {
      lastIsFullScreen = isFullScreen
      onFullScreenChange(isFullScreen)
    }

    // AppKit owns the native fullscreen presentation. Outside fullscreen,
    // align the existing button group idempotently before measuring its final
    // exclusion edge for collapsed browser chrome.
    if !window.styleMask.contains(.fullScreen) {
      alignStandardWindowButtons(in: window)
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

  /// Moves the native traffic-light group as a unit in window coordinates.
  /// The close button's top-left target is derived from the toolbar height and
  /// its measured frame. Points pass through window base coordinates before
  /// entering each titlebar superview, so flipped AppKit views are handled by
  /// NSView's conversion APIs rather than a guessed y-axis convention.
  private func alignStandardWindowButtons(in window: NSWindow) {
    guard let contentView = window.contentView,
      let closeButton = window.standardWindowButton(.closeButton)
    else {
      return
    }

    let buttonTypes: [NSWindow.ButtonType] = [
      .closeButton,
      .miniaturizeButton,
      .zoomButton,
    ]
    let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }
    guard buttons.count == buttonTypes.count else { return }

    let closeFrameInWindow = closeButton.convert(closeButton.bounds, to: nil)
    let nativeFramesInWindow = buttons.map { $0.convert($0.bounds, to: nil) }
    if trafficLightHorizontalOffsets == nil {
      trafficLightHorizontalOffsets = nativeFramesInWindow.dropFirst().map {
        $0.midX - closeFrameInWindow.midX
      }
    }
    guard let horizontalOffsets = trafficLightHorizontalOffsets,
      horizontalOffsets.count == buttons.count - 1
    else {
      return
    }

    let topInset = (BrowserChromeLayout.toolbarHeight - closeFrameInWindow.height) / 2
    let chromeCenterYInContent = contentView.isFlipped
      ? BrowserChromeLayout.toolbarHeight / 2
      : contentView.bounds.height - BrowserChromeLayout.toolbarHeight / 2
    let desiredCloseCenterInWindow = contentView.convert(
      CGPoint(x: topInset + closeFrameInWindow.width / 2, y: chromeCenterYInContent),
      to: nil)

    for (index, button) in buttons.enumerated() {
      guard let superview = button.superview else { continue }
      let horizontalDelta = index == 0 ? 0 : horizontalOffsets[index - 1]
      let targetCenterInWindow = CGPoint(
        x: desiredCloseCenterInWindow.x + horizontalDelta,
        y: desiredCloseCenterInWindow.y)
      let targetCenterInSuperview = superview.convert(targetCenterInWindow, from: nil)
      var targetFrame = button.frame
      targetFrame.origin = CGPoint(
        x: targetCenterInSuperview.x - targetFrame.width / 2,
        y: targetCenterInSuperview.y - targetFrame.height / 2)
      if button.frame != targetFrame {
        button.setFrameOrigin(targetFrame.origin)
      }
    }

    guard !didLogTrafficLightGeometry else { return }
    let alignedCloseFrameInWindow = closeButton.convert(closeButton.bounds, to: nil)
    let contentFrameInWindow = contentView.convert(contentView.bounds, to: nil)
    let measuredTopInset = contentView.isFlipped
      ? alignedCloseFrameInWindow.minY - contentFrameInWindow.minY
      : contentFrameInWindow.maxY - alignedCloseFrameInWindow.maxY
    let measuredLeftInset = alignedCloseFrameInWindow.minX - contentFrameInWindow.minX
    let closeCenterInContent = contentView.convert(
      CGPoint(x: alignedCloseFrameInWindow.midX, y: alignedCloseFrameInWindow.midY),
      from: nil)
    let measuredCenterYFromTop = contentView.isFlipped
      ? closeCenterInContent.y
      : contentView.bounds.height - closeCenterInContent.y
    let chromeCenterY = BrowserChromeLayout.toolbarHeight / 2
    let closeSize = "\(alignedCloseFrameInWindow.width)x\(alignedCloseFrameInWindow.height)"
    let metrics = [
      "close=\(closeSize)",
      "topInset=\(measuredTopInset)",
      "leftInset=\(measuredLeftInset)",
      "centerY=\(measuredCenterYFromTop)",
      "chromeCenterY=\(chromeCenterY)",
    ].joined(separator: " ")
    AppLog.app.debug("Traffic-light geometry \(metrics, privacy: .public)")
    didLogTrafficLightGeometry = true
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
