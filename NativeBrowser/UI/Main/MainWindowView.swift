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
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
      .padding(.top, 4)
      .background {
        GlassBackdrop()
          .ignoresSafeArea()
      }
      .frame(minWidth: 900, minHeight: 500)
      .onAppear { runtime.noteMainWindowAppeared() }
  }
}
