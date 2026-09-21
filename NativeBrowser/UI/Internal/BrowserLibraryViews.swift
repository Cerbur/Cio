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
    .frame(minWidth: 620, minHeight: 440)
  }
}

private struct HistoryLibraryView: View {
  @ObservedObject var history: HistoryService
  @ObservedObject var workspace: BrowserWorkspaceStore
  let dismiss: DismissAction
  @StateObject private var confirmationState = ClearHistoryConfirmationState()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("History")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Clear History", role: .destructive) {
          confirmationState.isShowing = true
        }
        .disabled(history.entries.isEmpty)
        LibraryCloseButton(title: "Close History", dismiss: dismiss)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 16)

      Divider()

      if history.entries.isEmpty {
        ContentUnavailableView(
          "No History",
          systemImage: "clock",
          description: Text("Completed HTTP and HTTPS page visits will appear here."))
      } else {
        List(history.entries) { entry in
          Button {
            guard workspace.loadInSelectedTab(entry.url) else { return }
            dismiss()
          } label: {
            HistoryRow(entry: entry)
          }
          .buttonStyle(.plain)
          .listRowSeparator(.visible)
          .accessibilityLabel("Open \(entry.title.isEmpty ? (entry.url.host ?? "History item") : entry.title)")
        }
        .listStyle(.inset)
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

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title)
            .font(.body.weight(.medium))
            .lineLimit(1)
          if entry.visitCount > 1 {
            Text("×\(entry.visitCount)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        Text(displayURL(for: entry.url))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(entry.lastVisitedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
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
      HStack {
        Text("Downloads")
          .font(.title2.weight(.semibold))
        Spacer()
        if downloads.activeDownloadCount > 0 {
          Text("\(downloads.activeDownloadCount) active")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        LibraryCloseButton(title: "Close Downloads", dismiss: dismiss)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 16)

      Divider()

      if downloads.items.isEmpty {
        ContentUnavailableView(
          "No Downloads",
          systemImage: "arrow.down.circle",
          description: Text("Files downloaded in this session will appear here."))
      } else {
        List(downloads.items) { item in
          DownloadRow(item: item, downloads: downloads)
            .listRowSeparator(.visible)
        }
        .listStyle(.inset)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct LibraryCloseButton: View {
  let title: String
  let dismiss: DismissAction

  var body: some View {
    Button {
      dismiss()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct DownloadRow: View {
  let item: DownloadItem
  @ObservedObject var downloads: DownloadManager

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: iconName)
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 6) {
        Text(item.fileName)
          .font(.body.weight(.medium))
          .lineLimit(1)
        if item.state == .downloading || item.state == .pending {
          if let progress = item.progress {
            ProgressView(value: progress)
            Text("\(formatBytes(item.receivedBytes)) of \(formatBytes(item.totalBytes ?? 0))")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            ProgressView()
            Text("\(formatBytes(item.receivedBytes)) received")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Text(item.state.displayName)
            .font(.caption)
            .foregroundStyle(item.state == .completed ? Color.secondary : Color.orange)
        }

        if item.state == .completed, item.destinationURL != nil {
          HStack(spacing: 12) {
            Button("Open") { downloads.open(item) }
            Button("Show in Finder") { downloads.showInFinder(item) }
          }
          .buttonStyle(.link)
          .font(.caption)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
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
