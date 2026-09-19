//
//  TabSidebarView.swift
//  NativeBrowser
//
//  The temporary vertical tab sidebar (Milestone 3 section 18).
//
//  Deliberately plain: a globe placeholder, a title, a loading spinner, a close
//  button and a "+" control. No favicon downloading, no drag reordering, no
//  pinning, no Liquid Glass - those are later milestones (sections 18 and 36).
//
//  The rows are value views over BrowserTab and call back into the manager; they
//  never own a BrowserSession, so a sidebar update can never create or destroy a
//  Chromium browser (section 2).
//

import SwiftUI

struct TabSidebarView: View {
  @ObservedObject var manager: BrowserSessionManager

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(manager.tabs) { tab in
            TabRowView(
              tab: tab,
              isSelected: tab.id == manager.selectedTabID,
              onSelect: { manager.selectTab(id: tab.id) },
              onClose: { manager.closeTab(id: tab.id) }
            )
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
      }
      .frame(maxHeight: .infinity)

      Divider()

      HStack(spacing: 6) {
        Button {
          manager.createTab(url: nil)
        } label: {
          Label("New Tab", systemImage: "plus")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .frame(width: 220)
    .background(Color(nsColor: .controlBackgroundColor))
  }
}

/// One sidebar row. A plain value view: it renders a BrowserTab and reports taps.
///
/// The close button is always drawn rather than revealed on hover: the row owns
/// no view state at all, which keeps it a pure function of the tab it renders and
/// keeps a sidebar update from being able to affect session ownership.
private struct TabRowView: View {
  let tab: BrowserTab
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      // Placeholder favicon: favicon downloading is a later milestone, so every
      // tab shows the same globe.
      Image(systemName: "globe")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 14)

      Text(tab.displayTitle)
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 4)

      if tab.isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .scaleEffect(0.5)
          .frame(width: 12, height: 12)
      }

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .frame(width: 14, height: 14)
      }
      .buttonStyle(.borderless)
      .help("Close Tab (⌘W)")
      .accessibilityLabel("Close Tab")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .help(tab.displayTitle)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
