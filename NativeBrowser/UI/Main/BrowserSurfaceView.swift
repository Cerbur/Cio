//
//  BrowserSurfaceView.swift
//  NativeBrowser
//
//  The single SwiftUI representable that hosts every live Chromium surface
//  (Milestone 3 sections 11 and 12).
//
//  One representable for the whole window, not one per tab. A per-tab
//  representable inside a selection test --
//
//      if tab.id == selectedTabID { ChromiumView(session: session) }
//
//  -- removes the inactive representable's NSView from the hierarchy, which
//  deallocates the CEF host view and destroys the CefBrowser. Switching back
//  would then build a second browser for the same tab.
//
//  Instead the AppKit BrowserSurfaceHostView owns one ChromiumContainerView per
//  live session, keeps all of them as subviews, and shows only the selected one.
//  `updateNSView` re-syncs that set; because the host - not SwiftUI - owns the
//  containers, no render can destroy a live browser.
//

import SwiftUI

struct BrowserSurfaceView: NSViewRepresentable {
  /// The runtime owner of the tabs and of the containers.
  @ObservedObject var manager: BrowserSessionManager

  func makeNSView(context: Context) -> BrowserSurfaceExtensionView {
    let extensionView = BrowserSurfaceExtensionView()
    manager.attachSurfaceHost(extensionView.surfaceHostView)
    return extensionView
  }

  func updateNSView(_ nsView: BrowserSurfaceExtensionView, context: Context) {
    // Idempotent: it re-adopts the same host, creates a container for any session
    // that does not have one yet, and never removes a container whose session is
    // still alive.
    manager.attachSurfaceHost(nsView.surfaceHostView)
  }
}
