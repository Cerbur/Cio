//
//  ChromiumView.swift
//  NativeBrowser
//
//  SwiftUI wrapper around the AppKit container that hosts the Chromium view
//  (ARCHITECTURE.md section 9).
//

import SwiftUI

struct ChromiumView: NSViewRepresentable {
  /// Runtime session that owns the Chromium browser rendered in this view.
  let session: BrowserSession

  func makeNSView(context: Context) -> ChromiumContainerView {
    let view = ChromiumContainerView()
    session.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: ChromiumContainerView, context: Context) {
    // The session drives the browser; a SwiftUI render must never rebuild the
    // Chromium view (ARCHITECTURE.md section 28). attach(to:) is idempotent and
    // only re-parents the browser when SwiftUI re-created the container.
    session.attach(to: nsView)
  }
}
