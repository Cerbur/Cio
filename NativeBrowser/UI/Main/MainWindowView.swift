//
//  MainWindowView.swift
//  NativeBrowser
//
//  SwiftUI scene host for the native AppKit browser shell.
//

import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var runtime: ApplicationRuntime

  var body: some View {
    NativeBrowserShellRepresentable(runtime: runtime)
      .frame(minWidth: 900, minHeight: 500)
      .onAppear { runtime.noteMainWindowAppeared() }
      .sheet(item: $runtime.presentedInternalPanel) { panel in
        BrowserLibrarySheet(
          panel: panel,
          history: runtime.historyService,
          downloads: runtime.downloadManager,
          workspace: runtime.workspaceStore)
      }
  }
}
