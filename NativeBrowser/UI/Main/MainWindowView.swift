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
      // Give the toolbar and navigation rail the same outer gutter.
      .padding([.top, .leading], BrowserLayout.shellInset)
      .background {
        GlassBackdrop()
          .ignoresSafeArea()
      }
      .frame(minWidth: 900, minHeight: 500)
      .onAppear { runtime.noteMainWindowAppeared() }
  }
}
