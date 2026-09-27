//
//  NavigationRail.swift
//  NativeBrowser
//
//  Section navigation floating beside the shared Main View.
//

import SwiftUI

struct NavigationRail: View {
  @ObservedObject var runtime: ApplicationRuntime

  private let buttonSize: CGFloat = 36

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 1.5) {
        sectionButton("Space", symbol: "house.fill", panel: nil)
        sectionButton("History", symbol: "clock.arrow.circlepath", panel: .history)
        sectionButton("Downloads", symbol: "arrow.down.circle", panel: .downloads)
      }
      // Balance the shell's leading inset against the split view's thin divider.
      .offset(x: -(BrowserLayout.shellInset - 1) / 2)
      Spacer(minLength: 0)
    }
    .padding(.top, 10.5)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }

  private func sectionButton(
    _ title: String,
    symbol: String,
    panel: ApplicationRuntime.InternalBrowserPanel?
  ) -> some View {
    let isSelected = runtime.presentedInternalPanel == panel
    return Button {
      switch panel {
      case .history: runtime.showHistory()
      case .downloads: runtime.showDownloads()
      case nil: runtime.presentedInternalPanel = nil
      }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 14.25, weight: isSelected ? .semibold : .regular))
        .frame(width: buttonSize, height: buttonSize)
        .contentShape(SidebarTabAppearance.glassShape)
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    .background {
      if isSelected {
        Color.clear.browserChromeGlassSurface(in: SidebarTabAppearance.glassShape)
      }
    }
    .overlay {
      if isSelected {
        SidebarTabAppearance.glassShape.strokeBorder(.white.opacity(0.5), lineWidth: 1)
      }
    }
    .help(title)
    .accessibilityLabel(title)
    .accessibilityIdentifier("browser-section-\(panel?.rawValue ?? "space")")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
