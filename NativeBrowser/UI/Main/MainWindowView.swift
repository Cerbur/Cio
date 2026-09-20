//
//  MainWindowView.swift
//  NativeBrowser
//
//  The Milestone 5 single-window layout: a glass Space/tab sidebar, one compact
//  toolbar, and one stable Chromium surface host containing every live session
//  across every Space.
//

import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var runtime: ApplicationRuntime

  var body: some View {
    BrowserWorkspaceView(workspace: runtime.workspaceStore)
      .frame(minWidth: 900, minHeight: 500)
      .background(Color(nsColor: .windowBackgroundColor))
      .onAppear { runtime.noteMainWindowAppeared() }
  }
}

private struct BrowserWorkspaceView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    HStack(spacing: 0) {
      TabSidebarView(workspace: workspace)
        .padding(.trailing, 12)

      BrowserContentColumn(workspace: workspace)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(12)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

/// The browser side of the window. The surface host remains a single
/// representable for the whole window; the toolbar and status bar are purely
/// presentational siblings around it.
private struct BrowserContentColumn: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    VStack(spacing: 8) {
      if let session = workspace.selectedSession {
        BrowserToolbarView(session: session)
          .addressFieldFocusListener(session: session)
      } else {
        Color.clear.frame(height: 52)
      }

      BrowserSurfaceFrame {
        // The runtime manager retains one container per live session. The
        // workspace store publishes only the effective selected tab; Space
        // switches therefore change visibility without recreating Chromium.
        BrowserSurfaceView(manager: workspace.sessionManager)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      BrowserStatusBar(workspace: workspace)
    }
  }
}

/// A quiet native frame around Chromium. It provides spacing and a semantic
/// border without clipping or masking the CEF child view.
private struct BrowserSurfaceFrame<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    ZStack {
      content()
    }
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
  }
}

/// Status information stays subordinate to the page while still making
/// loading and transient close/create work visible to the user.
private struct BrowserStatusBar: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    HStack(spacing: 7) {
      Image(
        systemName: (workspace.selectedSession?.lastErrorCode == nil)
          ? "globe" : "exclamationmark.triangle"
      )
      .foregroundStyle(
        workspace.selectedSession?.lastErrorCode == nil
          ? Color.secondary : Color.orange
      )

      Text(selectedStatusText)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 12)

      if workspace.liveSessionCount > workspace.allTabs.count {
        Text("closing \(workspace.liveSessionCount - workspace.allTabs.count)")
      }

      Text(workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs")
        .monospacedDigit()
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 4)
    .frame(height: 18)
  }

  private var selectedStatusText: String {
    guard let tab = workspace.selectedTab else { return "No tab" }
    if let session = workspace.selectedSession, session.lastErrorCode != nil {
      return "Unable to load page"
    }
    if tab.title.isEmpty && tab.url == nil { return "Loading…" }
    return tab.displayTitle
  }
}
