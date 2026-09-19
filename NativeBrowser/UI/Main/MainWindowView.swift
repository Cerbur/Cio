//
//  MainWindowView.swift
//  NativeBrowser
//
//  The Milestone 3 window: a vertical tab sidebar, one navigation toolbar bound
//  to the selected tab, and one Chromium surface host holding every live
//  browser. The Liquid Glass treatment belongs to Milestone 5 (ARCHITECTURE.md
//  sections 12-15).
//
//  There is deliberately one toolbar and one address field for the whole
//  window, not one per tab (Milestone 3 section 14). It is bound to
//  `manager.selectedSession`, so switching tabs switches the toolbar with it,
//  while a background tab's callbacks can only reach that tab's own session and
//  its own AddressFieldModel.
//

import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var runtime: ApplicationRuntime

  var body: some View {
    BrowserWorkspaceView(manager: runtime.sessionManager)
      .frame(minWidth: 900, minHeight: 500)
      .onAppear { runtime.noteMainWindowAppeared() }
  }
}

private struct BrowserWorkspaceView: View {
  @ObservedObject var manager: BrowserSessionManager

  var body: some View {
    HStack(spacing: 0) {
      TabSidebarView(manager: manager)

      Divider()

      VStack(spacing: 0) {
        if let session = manager.selectedSession {
          BrowserToolbarView(session: session)
            .addressFieldFocusListener(session: session)
        } else {
          Color.clear.frame(height: 44)
        }

        // One stable host for every live Chromium view. Switching tabs changes
        // which container is visible and nothing else, so no CefBrowser is
        // created or destroyed by a selection change (sections 11 and 12).
        BrowserSurfaceView(manager: manager)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        statusBar
      }
    }
  }

  private var selectedTab: BrowserTab? {
    manager.tabs.first { $0.id == manager.selectedTabID }
  }

  /// Keeps the selected page's title and the tab counts visible, which is what
  /// the multi-tab manual checks need; the sidebar carries the per-tab titles.
  private var statusBar: some View {
    HStack(spacing: 8) {
      Image(
        systemName: (manager.selectedSession?.lastErrorCode == nil)
          ? "globe" : "exclamationmark.triangle"
      )
      .foregroundStyle(.secondary)

      Text(selectedStatusText)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 12)

      if manager.liveSessionCount > manager.tabs.count {
        // A tab that has left the sidebar but whose browser has not reached
        // OnBeforeClose yet still counts as live (section 8).
        Text("closing \(manager.liveSessionCount - manager.tabs.count)")
      }

      Text(manager.tabs.count == 1 ? "1 tab" : "\(manager.tabs.count) tabs")
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
    guard let tab = selectedTab else { return "No tab" }
    if let session = manager.selectedSession, session.lastErrorCode != nil {
      return "Unable to load page"
    }
    if tab.title.isEmpty && tab.url == nil { return "Loading…" }
    return tab.displayTitle
  }
}
