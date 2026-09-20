//
//  TabSidebarView.swift
//  NativeBrowser
//
//  Plain Milestone 4 sidebar: all Spaces at the top, then the selected Space's
//  ordered tabs. The rows are value views and all lifecycle work goes through
//  BrowserWorkspaceStore.
//

import AppKit
import SwiftUI

struct TabSidebarView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text("Spaces")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

          ForEach(workspace.spaces) { space in
            SpaceRowView(
              space: space,
              isSelected: space.id == workspace.selectedSpaceID,
              workspace: workspace)
          }

          Button {
            workspace.createSpace()
          } label: {
            Label("New Space", systemImage: "plus")
              .labelStyle(.titleAndIcon)
          }
          .buttonStyle(.borderless)
          .help("New Space")
          .accessibilityLabel("New Space")
          .padding(.horizontal, 12)
          .padding(.vertical, 7)

          Divider()
            .padding(.vertical, 5)

          Text(workspace.selectedSpace?.name ?? "Tabs")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

          LazyVStack(spacing: 2) {
            ForEach(workspace.tabs) { tab in
              TabRowView(
                tab: tab,
                isSelected: tab.id == workspace.selectedTabID,
                onSelect: { workspace.selectTab(id: tab.id) },
                onClose: { workspace.closeTab(id: tab.id) })
            }
          }
          .padding(.horizontal, 6)
        }
        .padding(.bottom, 8)
      }
      .frame(maxHeight: .infinity)

      Divider()

      HStack(spacing: 6) {
        Button {
          workspace.createTab(url: nil)
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

private struct SpaceRowView: View {
  let space: BrowserSpace
  let isSelected: Bool
  @ObservedObject var workspace: BrowserWorkspaceStore

  var body: some View {
    Button {
      workspace.selectSpace(id: space.id)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: isSelected ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
          .font(.system(size: 11))
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
          .frame(width: 14)
        Text(space.name)
          .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        Text("\(space.tabIDs.count)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Rename") {
        promptRename()
      }
    }
  }

  private func promptRename() {
    let alert = NSAlert()
    alert.messageText = "Rename Space"
    alert.informativeText = "Surrounding whitespace is trimmed."
    let field = NSTextField(string: space.name)
    field.frame.size = NSSize(width: 240, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    workspace.renameSpace(id: space.id, name: field.stringValue)
  }
}

/// One sidebar tab row. It renders a BrowserTab and reports actions; it never
/// owns a BrowserSession or decides which Space a tab belongs to.
private struct TabRowView: View {
  let tab: BrowserTab
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 6) {
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
