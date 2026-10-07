//
//  MainWindowView.swift
//  Cio
//
//  SwiftUI scene host for the native AppKit browser shell.
//

import SwiftUI

public struct MainWindowView: View {
  public init() {}
  @EnvironmentObject private var runtime: BrowserUIContext

  public var body: some View {
    CioShellRepresentable(runtime: runtime)
      // The shell owns toolbar/rail geometry, including the native titlebar area.
      .ignoresSafeArea(.container)
      .background {
        GlassBackdrop()
          .ignoresSafeArea()
      }
      .frame(minWidth: 900, minHeight: 500)
      .onAppear { runtime.noteMainWindowAppeared() }
  }
}
