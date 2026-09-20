//
//  MainWindowView.swift
//  NativeBrowser
//
//  The plain Milestone 4 single-window layout: Space switcher + current Space
//  tabs, one toolbar, and one stable Chromium surface host containing every
//  live session across every Space.
//

import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var runtime: ApplicationRuntime

  var body: some View {
    BrowserWorkspaceView(workspace: runtime.workspaceStore)
      .frame(minWidth: 900, minHeight: 500)
      .onAppear { runtime.noteMainWindowAppeared() }
  }
}

private struct BrowserWorkspaceView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    HStack(spacing: 0) {
      TabSidebarView(workspace: workspace)

      Divider()

      VStack(spacing: 0) {
        if let session = workspace.selectedSession {
          BrowserToolbarView(session: session)
            .addressFieldFocusListener(session: session)
        } else {
          Color.clear.frame(height: 44)
        }

        // The runtime manager retains one container per live session. The
        // workspace store publishes only the effective selected tab; Space
        // switches therefore change visibility without recreating Chromium.
        BrowserSurfaceView(manager: workspace.sessionManager)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        statusBar
      }
    }
  }

  private var statusBar: some View {
    HStack(spacing: 8) {
      Image(
        systemName: (workspace.selectedSession?.lastErrorCode == nil)
          ? "globe" : "exclamationmark.triangle"
      )
      .foregroundStyle(.secondary)

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
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(alignment: .top) {
      Divider()
    }
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
