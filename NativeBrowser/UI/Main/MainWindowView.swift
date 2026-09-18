//
//  MainWindowView.swift
//  NativeBrowser
//
//  Milestone 2 window content: the native navigation toolbar (Back, Forward,
//  Reload/Stop, address field) above the Chromium content, and a slim status
//  line showing the page title from CEF. Tabs, the sidebar and the Liquid Glass
//  treatment belong to later milestones (ARCHITECTURE.md sections 12-15).
//
//  The Chromium view is created once and never rebuilt: everything the toolbar
//  pushes through (URL, title, loading state, address text) only changes
//  @Published state on BrowserSession, and ChromiumView is keyed by the session
//  so SwiftUI keeps the same AppKit container (Milestone 2, section 20).
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
      BrowserToolbarView(session: session)
        .addressFieldFocusListener(session: session)

      ChromiumView(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      statusBar
    }
  }

  /// Keeps the page title visible, which Milestone 3 needs per tab. The command
  /// bar itself is above the content.
  private var statusBar: some View {
    HStack(spacing: 8) {
      Image(systemName: session.lastErrorCode == nil ? "globe" : "exclamationmark.triangle")
        .foregroundStyle(.secondary)
      Text(session.title.isEmpty ? "Loading…" : session.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 12)
      if session.isClosed {
        Text("closed")
      }
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(alignment: .top) {
      Divider()
    }
  }
}
