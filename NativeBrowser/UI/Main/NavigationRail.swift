//
//  NavigationRail.swift
//  NativeBrowser
//
//  Section navigation floating beside the shared Main View.
//

import SwiftUI

struct NavigationRail: View {
  @ObservedObject var runtime: ApplicationRuntime

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 2) {
        sectionButton("Space", symbol: "house.fill", panel: nil)
        sectionButton("History", symbol: "clock.arrow.circlepath", panel: .history)
        sectionButton("Downloads", symbol: "arrow.down.circle", panel: .downloads)
      }
      .padding(4)
      .browserChromeGlassSurface(in: Capsule())
      Spacer(minLength: 0)
    }
    .padding(.top, 14)
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
        .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
        .frame(width: 48, height: 48)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    .background {
      if isSelected {
        Capsule()
          .fill(Color.primary.opacity(0.11))
      }
    }
    .help(title)
    .accessibilityLabel(title)
    .accessibilityIdentifier("browser-section-\(panel?.rawValue ?? "space")")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
