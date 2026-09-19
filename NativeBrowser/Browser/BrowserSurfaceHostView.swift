//
//  BrowserSurfaceHostView.swift
//  NativeBrowser
//
//  The stable AppKit host for every live Chromium surface in the window
//  (Milestone 3 section 11).
//
//  Why this type exists: the obvious SwiftUI implementation of tab selection --
//
//      if tab.id == selectedTabID { ChromiumView(session: session) }
//
//  removes the inactive representable's NSView from the hierarchy, which
//  deallocates the CEF host view, which destroys the CefBrowser. Switching back
//  then builds a second browser for the same tab, and every switch loses the
//  tab's page state.
//
//  Instead, each live BrowserSession owns exactly one ChromiumContainerView that
//  stays a subview of this host for as long as the session is alive. Selection
//  only changes which container is visible; no browser is created, destroyed or
//  reparented by a tab switch.
//
//  The host creates and destroys nothing: the session manager owns the
//  containers and hands the current set in, so "remove a container" can only
//  happen after OnBeforeClose released its session.
//

import AppKit

final class BrowserSurfaceHostView: NSView {
  /// Lays out exactly `containers` and makes the selected one visible.
  ///
  /// Containers that are no longer in the set are removed from the hierarchy;
  /// by the time that happens their session has reached OnBeforeClose, so the
  /// CEF view they hosted is already gone.
  func present(containers: [UUID: ChromiumContainerView], selectedTabID: UUID?) {
    var presented = Set<ObjectIdentifier>()
    for (tabID, container) in containers {
      presented.insert(ObjectIdentifier(container))
      if container.superview !== self {
        container.removeFromSuperview()
        addSubview(container)
      }
      container.frame = bounds
      container.autoresizingMask = [.width, .height]
      container.setSurfaceVisible(tabID == selectedTabID)
    }

    for subview in subviews {
      guard let container = subview as? ChromiumContainerView else { continue }
      if !presented.contains(ObjectIdentifier(container)) {
        container.removeFromSuperview()
      }
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    autoresizesSubviews = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
