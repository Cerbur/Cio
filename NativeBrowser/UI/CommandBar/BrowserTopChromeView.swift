//
//  BrowserTopChromeView.swift
//  NativeBrowser
//
//  The one presentation layer for the browser's 44-point top chrome. It owns
//  the sidebar controls, navigation controls and address field so the sidebar
//  body and Chromium surface never create competing toolbar rows.
//

import AppKit
import SwiftUI

/// The single browser chrome band shared by the expanded and collapsed shell.
/// The native traffic lights remain owned by NSWindow; the measured inset only
/// excludes them horizontally when the sidebar is collapsed.
struct BrowserTopChromeView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  @Binding var isSidebarVisible: Bool
  let titlebarLeadingControlInset: CGFloat

  var body: some View {
    chromeContent
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: BrowserChromeLayout.toolbarHeight)
      .browserToolbarMaterial()
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color.primary.opacity(0.09))
          .frame(height: 0.5)
          .allowsHitTesting(false)
      }
  }

  @ViewBuilder
  private var chromeContent: some View {
    if let session = workspace.selectedSession {
      BrowserTopChromeControls(
        session: session,
        isSidebarVisible: isSidebarVisible,
        titlebarLeadingControlInset: titlebarLeadingControlInset,
        onCreateTab: { workspace.createTab(url: nil) },
        onCollapseSidebar: { isSidebarVisible = false },
        onShowSidebar: { isSidebarVisible = true })
        .addressFieldFocusListener(session: session)
    } else {
      // A session can be absent for one short transition while a selected tab's
      // old Chromium runtime is closing. Keep the complete chrome geometry in
      // place and leave navigation/address content unavailable rather than
      // replacing the band with a blank spacer or a fake session.
      BrowserTopChromeControls(
        session: nil,
        isSidebarVisible: isSidebarVisible,
        titlebarLeadingControlInset: titlebarLeadingControlInset,
        onCreateTab: { workspace.createTab(url: nil) },
        onCollapseSidebar: { isSidebarVisible = false },
        onShowSidebar: { isSidebarVisible = true })
    }
  }
}

private struct BrowserTopChromeControls: View {
  let session: BrowserSession?
  let isSidebarVisible: Bool
  let titlebarLeadingControlInset: CGFloat
  let onCreateTab: () -> Void
  let onCollapseSidebar: () -> Void
  let onShowSidebar: () -> Void
  @StateObject private var interaction = BrowserInteractionState()

  private var navigationState: NavigationState? {
    session?.navigationState
  }

  private var addressFieldIsFocused: Bool {
    interaction.isFocused || session?.addressField.isEditing == true
  }

  var body: some View {
    HStack(spacing: 0) {
      if isSidebarVisible {
        expandedSidebarControls
          .transition(.opacity)
      } else {
        BrowserGlassStandaloneIconButton(
          systemImage: "sidebar.left",
          label: "Show Sidebar",
          action: onShowSidebar)
          .padding(.trailing, BrowserChromeLayout.sidebarToggleToNav)
          .transition(.opacity)
      }

      navigationControls
        .padding(
          .leading,
          isSidebarVisible ? BrowserChromeLayout.expandedNavigationLeadingPadding : 0)
        .padding(.trailing, BrowserChromeLayout.navToAddress)

      addressFieldSurface(
        session: session,
        isFocused: addressFieldIsFocused)
        .layoutPriority(1)

      loadingIndicator
    }
    .padding(.leading, isSidebarVisible ? 0 : max(0, titlebarLeadingControlInset))
    .padding(.trailing, BrowserChromeLayout.chromeTrailingPadding)
    .padding(.vertical, BrowserChromeLayout.chromeVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: BrowserChromeLayout.toolbarHeight)
  }

  private var expandedSidebarControls: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)

      BrowserGlassControlGroup {
        BrowserGlassIconButton(
          systemImage: "plus.square.on.square",
          label: "New Tab",
          action: onCreateTab)
        BrowserGlassIconButton(
          systemImage: "sidebar.left",
          label: "Hide Sidebar",
          action: onCollapseSidebar)
      }
    }
    .padding(.trailing, BrowserChromeLayout.chromeTrailingPadding)
    .frame(width: BrowserChromeLayout.sidebarWidth)
  }

  private var navigationControls: some View {
    BrowserGlassControlGroup {
      BrowserGlassIconButton(
        systemImage: "chevron.backward",
        label: "Back",
        isEnabled: navigationState?.canGoBack == true,
        action: { session?.goBack() })
      BrowserGlassIconButton(
        systemImage: "chevron.forward",
        label: "Forward",
        isEnabled: navigationState?.canGoForward == true,
        action: { session?.goForward() })
      BrowserGlassIconButton(
        systemImage: navigationState?.isLoading == true ? "xmark" : "arrow.clockwise",
        label: navigationState?.isLoading == true ? "Stop" : "Reload",
        isEnabled: session != nil,
        action: { session?.reloadOrStop() })
    }
  }

  @ViewBuilder
  private func addressFieldSurface(session: BrowserSession?, isFocused: Bool) -> some View {
    HStack(spacing: 7) {
      Image(systemName: "globe")
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.secondary.opacity(0.88))
        .frame(width: 14)
        .allowsHitTesting(false)

      if let session {
        AddressField(
          model: session.addressField,
          onChange: { session.addressField.userChangedText($0) },
          onSubmit: { session.submitAddressField() },
          onEscape: { session.cancelAddressEditing() },
          onFocusChange: { focused in
            interaction.isFocused = focused
            session.addressFieldFocusChanged(focused)
          }
        )
        .frame(minWidth: 240, maxWidth: .infinity, minHeight: 20, idealHeight: 22)
        .layoutPriority(1)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
      } else {
        // Keep an empty address surface during a runtime hand-off. This is
        // intentionally not a BrowserSession placeholder.
        Color.clear
          .frame(minWidth: 240, maxWidth: .infinity, minHeight: 20, idealHeight: 22)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 1)
    .browserAddressFieldSurface(isFocused: isFocused, cornerRadius: 10)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isFocused
            ? Color.accentColor.opacity(0.38)
            : Color.primary.opacity(0.13),
          lineWidth: isFocused ? 1 : 0.5
        )
        .allowsHitTesting(false)
    }
    .allowsHitTesting(true)
  }

  private var loadingIndicator: some View {
    ZStack {
      if navigationState?.isLoading == true {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .scaleEffect(0.6)
          .help("Loading")
      }
    }
    .frame(width: 16, height: 14)
    .accessibilityHidden(navigationState?.isLoading != true)
  }

}

/// Applies a ⌘L focus request to the AppKit address field belonging to one
/// session. The field itself remains a native NSTextField representable.
private struct AddressFieldFocusListener: ViewModifier {
  let session: BrowserSession

  func body(content: Content) -> some View {
    content.onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressField)) {
      notification in
      guard notification.object as AnyObject? === session else { return }
      NotificationCenter.default.post(
        name: .browserAddressFieldShouldFocus, object: session.addressField)
    }
  }
}

extension View {
  /// Makes the address field of the session take focus when ⌘L is pressed.
  func addressFieldFocusListener(session: BrowserSession) -> some View {
    modifier(AddressFieldFocusListener(session: session))
  }
}
