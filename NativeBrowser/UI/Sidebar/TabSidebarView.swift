//
//  TabSidebarView.swift
//  NativeBrowser
//
//  Milestone 5.1 sidebar: all Spaces at the top, then the selected Space's
//  ordered tabs inside one continuous native sidebar material. The rows are
//  value views and all lifecycle work goes through BrowserWorkspaceStore.
//

import AppKit
import SwiftUI

private enum SidebarLayout {
  static let width: CGFloat = 248
  static let rowCornerRadius: CGFloat = 6
  static let spaceRowHeight: CGFloat = 27
  static let tabRowHeight: CGFloat = 32
  static let closeHitTarget: CGFloat = 24
}

struct TabSidebarView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  @EnvironmentObject private var runtime: ApplicationRuntime
  @Environment(\.browserTitlebarContentInset) private var titlebarContentInset

  var body: some View {
    VStack(spacing: 0) {
      // This spacer belongs outside the scroll view so rows never move under
      // the native traffic lights when the sidebar content is scrolled.
      Color.clear
        .frame(height: max(titlebarContentInset, 8))

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader {
              workspace.createSpace()
            } help: {
              "New Space"
            }
            .padding(.bottom, 6)

            LazyVStack(spacing: 1) {
              ForEach(workspace.spaces) { space in
                SpaceRowView(
                  space: space,
                  isSelected: space.id == workspace.selectedSpaceID,
                  workspace: workspace)
                  .id("space-\(space.id.uuidString)")
              }
            }

            Rectangle()
              .fill(Color.primary.opacity(0.08))
              .frame(height: 0.5)
              .padding(.vertical, 8)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
              Text("Tabs")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

              Spacer(minLength: 4)

              Text("\(workspace.tabs.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 5)

            LazyVStack(spacing: 1) {
              ForEach(workspace.tabs) { tab in
                TabRowView(
                  tab: tab,
                  isSelected: tab.id == workspace.selectedTabID,
                  onSelect: { workspace.selectTab(id: tab.id) },
                  onClose: { workspace.closeTab(id: tab.id) })
                  .id("tab-\(tab.id.uuidString)")
              }
            }
            .padding(.horizontal, 3)
          }
          .padding(.horizontal, 6)
          .padding(.top, 8)
          .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: workspace.selectedSpaceID) { _, id in
          proxy.scrollTo("space-\(id.uuidString)", anchor: .center)
        }
        .onChange(of: workspace.selectedTabID) { _, id in
          guard let id else { return }
          proxy.scrollTo("tab-\(id.uuidString)", anchor: .center)
        }
      }

      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(height: 0.5)

      HStack(spacing: 8) {
        Button {
          workspace.createTab(url: nil)
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 20, height: 20)
            .background(
              Circle().fill(Color.accentColor.opacity(0.12))
            )
            .foregroundStyle(Color.accentColor)
          Text("New Tab")
            .font(.callout.weight(.medium))
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
        .contentShape(Rectangle())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.top, 8)

      VStack(spacing: 2) {
        SidebarUtilityButton(
          title: "History",
          systemImage: "clock",
          action: runtime.showHistory)
        SidebarUtilityButton(
          title: "Downloads",
          systemImage: "arrow.down.circle",
          badge: runtime.downloadManager.activeDownloadCount,
          action: runtime.showDownloads)
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 11)
    }
    .frame(width: SidebarLayout.width)
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

private struct SidebarUtilityButton: View {
  let title: String
  let systemImage: String
  var badge: Int = 0
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 16)
        Text(title)
          .font(.callout)
        Spacer(minLength: 4)
        if badge > 0 {
          Text("\(badge)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct SidebarSectionHeader: View {
  let action: () -> Void
  let help: () -> String

  var body: some View {
    HStack(spacing: 8) {
      Text("Spaces")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)

      Spacer(minLength: 4)

      Button(action: action) {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
      .help(help())
      .accessibilityLabel(help())
    }
    .padding(.horizontal, 10)
  }
}

private struct SpaceRowView: View {
  let space: BrowserSpace
  let isSelected: Bool
  @ObservedObject var workspace: BrowserWorkspaceStore
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    Button {
      workspace.selectSpace(id: space.id)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: isSelected ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
          .font(.system(size: 12, weight: isSelected ? .medium : .regular))
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
          .frame(width: 16)
        Text(space.name)
          .font(.footnote.weight(isSelected ? .medium : .regular))
          .lineLimit(1)
          .truncationMode(.tail)
          Spacer(minLength: 4)
          Text("\(space.tabIDs.count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(isSelected ? Color.accentColor.opacity(0.9) : .secondary)
      }
      .padding(.horizontal, 8)
      .frame(height: SidebarLayout.spaceRowHeight)
      .background(
        RoundedRectangle(cornerRadius: SidebarLayout.rowCornerRadius, style: .continuous)
          .fill(
            isSelected
              ? Color.primary.opacity(0.075)
              : (interaction.isHovered ? Color.primary.opacity(0.05) : Color.clear)
          )
      )
      .overlay(alignment: .leading) {
        if isSelected {
          Rectangle()
            .fill(Color.accentColor.opacity(0.95))
            .frame(width: 2, height: 14)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { interaction.isHovered = $0 }
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
        HStack(spacing: 7) {
          Image(systemName: "globe")
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(width: 16)

          Text(tab.displayTitle)
            .font(.callout.weight(isSelected ? .medium : .regular))
            .lineLimit(1)
            .truncationMode(.tail)

          Spacer(minLength: 4)

          // Keep a stable status slot so loading never changes title width.
          ZStack {
            Color.clear
            if tab.isLoading {
              ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.55)
            }
          }
          .frame(width: 16, height: 16)

          // Reserve space for the close control so revealing it never changes
          // the title's layout or makes the sidebar jump.
          Color.clear.frame(
            width: SidebarLayout.closeHitTarget,
            height: SidebarLayout.closeHitTarget)
        }
        .padding(.horizontal, 8)
        .frame(height: SidebarLayout.tabRowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .frame(
            width: SidebarLayout.closeHitTarget,
            height: SidebarLayout.closeHitTarget)
          .foregroundStyle(isSelected ? Color.primary : .secondary)
          .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(Color.primary.opacity(interaction.isHovered ? 0.09 : 0.045))
          )
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
      .opacity(interaction.isHovered || isSelected ? 1 : 0)
      .allowsHitTesting(interaction.isHovered || isSelected)
      .accessibilityHidden(false)
      .help("Close Tab (⌘W)")
      .accessibilityLabel("Close Tab")
    }
    .padding(.horizontal, 2)
    .background(
      RoundedRectangle(cornerRadius: SidebarLayout.rowCornerRadius, style: .continuous)
        .fill(
          isSelected
            ? Color.primary.opacity(0.105)
            : (interaction.isHovered ? Color.primary.opacity(0.055) : Color.clear)
        )
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Rectangle()
          .fill(Color.accentColor.opacity(0.95))
          .frame(width: 2, height: 18)
      }
    }
    .onHover { interaction.isHovered = $0 }
    .help(tab.displayTitle)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
