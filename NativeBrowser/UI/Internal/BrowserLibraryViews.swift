//
//  BrowserLibraryViews.swift
//  NativeBrowser
//
//  Native History and Downloads presentation. These views are shown as an
//  AppKit-backed SwiftUI sheet, so BrowserSurfaceHostView and all live CEF
//  containers remain mounted in the main window.
//

import AppKit
import SwiftUI

struct BrowserLibrarySheet: View {
  let panel: ApplicationRuntime.InternalBrowserPanel
  @ObservedObject var history: HistoryService
  @ObservedObject var downloads: DownloadManager
  @ObservedObject var workspace: BrowserWorkspaceStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      switch panel {
      case .history:
        HistoryLibraryView(history: history, workspace: workspace, dismiss: dismiss)
      case .downloads:
        DownloadsLibraryView(downloads: downloads, dismiss: dismiss)
      }
    }
    .frame(minWidth: LibraryLayout.minWidth, minHeight: LibraryLayout.minHeight)
  }
}

private enum LibraryLayout {
  static let minWidth: CGFloat = 620
  static let minHeight: CGFloat = 440
  static let headerHorizontalPadding: CGFloat = 20
  static let headerVerticalPadding: CGFloat = 12
  static let rowHorizontalPadding: CGFloat = 14
  static let rowVerticalPadding: CGFloat = 3
  static let rowCornerRadius: CGFloat = 6
  static let iconColumnWidth: CGFloat = 24
  static let separatorOpacity: CGFloat = 0.09
  static let downloadStatusHeight: CGFloat = 22
  static let downloadActionHeight: CGFloat = 16
}

private struct HistoryLibraryView: View {
  @ObservedObject var history: HistoryService
  @ObservedObject var workspace: BrowserWorkspaceStore
  let dismiss: DismissAction
  @StateObject private var confirmationState = ClearHistoryConfirmationState()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("History")
          .font(.headline.weight(.semibold))
        Spacer()
        Button("Clear History", role: .destructive) {
          confirmationState.isShowing = true
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(history.entries.isEmpty)
        LibraryCloseButton(title: "Close History", dismiss: dismiss)
      }
      .padding(.horizontal, LibraryLayout.headerHorizontalPadding)
      .padding(.vertical, LibraryLayout.headerVerticalPadding)
      .frame(minHeight: 52)

      LibrarySeparator()

      if history.entries.isEmpty {
        LibraryEmptyState(
          title: "No History",
          systemImage: "clock",
          message: "Completed HTTP and HTTPS page visits will appear here.")
      } else {
        List(history.entries) { entry in
          Button {
            guard workspace.loadInSelectedTab(entry.url) else { return }
            dismiss()
          } label: {
            HistoryRow(entry: entry)
          }
          .buttonStyle(.plain)
          .listRowSeparator(.visible, edges: .all)
          .listRowInsets(
            EdgeInsets(
              top: LibraryLayout.rowVerticalPadding,
              leading: LibraryLayout.rowHorizontalPadding,
              bottom: LibraryLayout.rowVerticalPadding,
              trailing: LibraryLayout.rowHorizontalPadding))
          .listRowBackground(Color.clear)
          .accessibilityLabel("Open \(entry.title.isEmpty ? (entry.url.host ?? "History item") : entry.title)")
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .alert("Clear History?", isPresented: $confirmationState.isShowing) {
      Button("Clear History", role: .destructive) {
        history.clear()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes saved History entries only. It does not close tabs or clear cookies, cache, or passwords.")
    }
  }
}

@MainActor
private final class ClearHistoryConfirmationState: ObservableObject {
  @Published var isShowing = false
}

private struct HistoryRow: View {
  let entry: HistoryEntry
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
        .frame(width: LibraryLayout.iconColumnWidth, height: 22)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title)
            .font(.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
          if entry.visitCount > 1 {
            Text("×\(entry.visitCount)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Text(entry.lastVisitedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Text(displayURL(for: entry.url))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: LibraryLayout.rowCornerRadius, style: .continuous)
        .fill(interaction.isHovered ? Color.primary.opacity(0.055) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { interaction.isHovered = $0 }
  }

  private func displayURL(for url: URL) -> String {
    var value = url.host ?? url.absoluteString
    if let port = url.port { value += ":\(port)" }
    if !url.path.isEmpty, url.path != "/" { value += url.path }
    return value
  }
}

private struct DownloadsLibraryView: View {
  @ObservedObject var downloads: DownloadManager
  let dismiss: DismissAction

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("Downloads")
          .font(.headline.weight(.semibold))
        Spacer()
        if downloads.activeDownloadCount > 0 {
          Text("\(downloads.activeDownloadCount) active")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
        LibraryCloseButton(title: "Close Downloads", dismiss: dismiss)
      }
      .padding(.horizontal, LibraryLayout.headerHorizontalPadding)
      .padding(.vertical, LibraryLayout.headerVerticalPadding)
      .frame(minHeight: 52)

      LibrarySeparator()

      if downloads.items.isEmpty {
        LibraryEmptyState(
          title: "No Downloads",
          systemImage: "arrow.down.circle",
          message: "Files downloaded in this session will appear here.")
      } else {
        List(downloads.items) { item in
          DownloadRow(item: item, downloads: downloads)
            .listRowSeparator(.visible, edges: .all)
            .listRowInsets(
              EdgeInsets(
                top: LibraryLayout.rowVerticalPadding,
                leading: LibraryLayout.rowHorizontalPadding,
                bottom: LibraryLayout.rowVerticalPadding,
                trailing: LibraryLayout.rowHorizontalPadding))
            .listRowBackground(Color.clear)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct LibrarySeparator: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(LibraryLayout.separatorOpacity))
      .frame(height: 0.5)
      .allowsHitTesting(false)
  }
}

private struct LibraryEmptyState: View {
  let title: String
  let systemImage: String
  let message: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.tertiary)
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(28)
  }
}

private struct LibraryCloseButton: View {
  let title: String
  let dismiss: DismissAction
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    Button {
      dismiss()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(LibraryCloseButtonStyle(isHovered: interaction.isHovered))
    .onHover { interaction.isHovered = $0 }
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct LibraryCloseButtonStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color.primary.opacity(0.72))
      .background(
        RoundedRectangle(cornerRadius: LibraryLayout.rowCornerRadius, style: .continuous)
          .fill(
            configuration.isPressed
              ? Color.primary.opacity(0.14)
              : (isHovered ? Color.primary.opacity(0.075) : Color.clear)
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: LibraryLayout.rowCornerRadius, style: .continuous))
  }
}

private struct DownloadRow: View {
  let item: DownloadItem
  @ObservedObject var downloads: DownloadManager
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: iconName)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(stateTint)
        .frame(width: LibraryLayout.iconColumnWidth, height: 24)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.fileName)
            .font(.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
          Spacer(minLength: 8)
          Text(item.state.displayName)
            .font(.caption.weight(.medium))
            .foregroundStyle(stateTint)
            .lineLimit(1)
        }

        Group {
          if isActive {
            VStack(alignment: .leading, spacing: 4) {
              ProgressView(value: item.progress)
                .tint(Color.accentColor.opacity(0.82))
                .frame(height: 5)
              HStack(spacing: 8) {
                Text(progressDetail)
                if let progress = item.progress {
                  Spacer(minLength: 4)
                  Text("\(Int(progress * 100))%")
                    .font(.caption2.monospacedDigit())
                }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          } else {
            HStack(spacing: 6) {
              if let sizeLabel {
                Text(sizeLabel)
              }
              if let locationLabel {
                metadataSeparator
                Text(locationLabel)
              }
              if let finishedAt = item.finishedAt {
                metadataSeparator
                Text(finishedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          }
        }
        .frame(height: LibraryLayout.downloadStatusHeight, alignment: .top)

        Group {
          if item.state == .completed, item.destinationURL != nil {
            HStack(spacing: 12) {
              Button("Open") { downloads.open(item) }
              Button("Show in Finder") { downloads.showInFinder(item) }
            }
            .buttonStyle(.link)
            .font(.caption)
          } else {
            Color.clear
          }
        }
        .frame(height: LibraryLayout.downloadActionHeight, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: LibraryLayout.rowCornerRadius, style: .continuous)
        .fill(interaction.isHovered ? Color.primary.opacity(0.055) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { interaction.isHovered = $0 }
  }

  private var isActive: Bool {
    item.state == .downloading || item.state == .pending
  }

  private var stateTint: Color {
    switch item.state {
    case .pending, .downloading:
      return Color.accentColor.opacity(0.86)
    case .completed:
      return Color.secondary
    case .failed:
      return Color.orange.opacity(0.64)
    case .cancelled:
      return Color.secondary.opacity(0.82)
    }
  }

  private var sizeLabel: String? {
    let bytes = item.totalBytes ?? item.receivedBytes
    return bytes > 0 ? formatBytes(bytes) : nil
  }

  private var locationLabel: String? {
    guard let destination = item.destinationURL else { return nil }
    let folder = destination.deletingLastPathComponent().lastPathComponent
    return folder.isEmpty ? nil : folder
  }

  @ViewBuilder
  private var metadataSeparator: some View {
    Text("·")
      .foregroundStyle(.tertiary)
  }

  private var progressDetail: String {
    if let totalBytes = item.totalBytes, totalBytes > 0 {
      return "\(formatBytes(item.receivedBytes)) of \(formatBytes(totalBytes))"
    }
    return "\(formatBytes(item.receivedBytes)) received"
  }

  private var iconName: String {
    switch item.state {
    case .completed: return "checkmark.circle"
    case .failed: return "exclamationmark.circle"
    case .cancelled: return "xmark.circle"
    case .pending, .downloading: return "arrow.down.circle"
    }
  }

  private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
