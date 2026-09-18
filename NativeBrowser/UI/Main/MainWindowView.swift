//
//  MainWindowView.swift
//  NativeBrowser
//
//  Milestone 1 window content: one Chromium view filling the window, plus a
//  read-only status line that shows the navigation callbacks (title, URL,
//  loading state). Tabs, the sidebar and the interactive command bar belong to
//  later milestones (ARCHITECTURE.md sections 12-15).
//

import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var runtime: ApplicationRuntime

  var body: some View {
    BrowserContentView(session: runtime.browserSession)
      .frame(minWidth: 640, minHeight: 400)
      .onAppear { runtime.record("swiftui:main-window-appeared") }
  }
}

private struct BrowserContentView: View {
  @ObservedObject var session: BrowserSession

  var body: some View {
    VStack(spacing: 0) {
      ChromiumView(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      statusBar
    }
  }

  /// Read-only status. Milestone 2 replaces it with the command bar.
  private var statusBar: some View {
    HStack(spacing: 8) {
      if session.isLoading {
        ProgressView()
          .controlSize(.small)
          .scaleEffect(0.6)
          .frame(width: 12, height: 12)
      } else {
        Image(systemName: session.lastErrorCode == nil ? "globe" : "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
      Text(session.title.isEmpty ? "Loading…" : session.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 12)
      Text(session.url?.absoluteString ?? session.initialURL.absoluteString)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }
}
