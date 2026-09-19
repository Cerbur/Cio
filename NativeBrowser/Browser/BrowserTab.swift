//
//  BrowserTab.swift
//  NativeBrowser
//
//  The CEF-independent tab model (ARCHITECTURE.md sections 6 and 42; Milestone 3
//  section 4).
//
//  BrowserTab is the *identity* of a tab. It deliberately contains no CEF type,
//  no BrowserBridge and no BrowserSession: the tab collection, the ordering
//  rules and the recently-closed stack are defined without Chromium so they can
//  be reasoned about - and unit tested - with no browser in the process.
//
//  Kept dependency free (Foundation only) so it compiles into both the
//  application target and the unit test bundle (see project.yml).
//

import Foundation

/// One tab in the workspace.
///
/// A tab outlives neither the window nor the application, but it is *not* the
/// runtime: the Chromium browser that renders it lives in the BrowserSession the
/// session manager keys by `id`. No CEF type is named in this file at all - the
/// verification script checks that - which is what keeps the tab model testable
/// without Chromium.
struct BrowserTab: Identifiable, Equatable, Sendable {
  /// Stable identity, independent of every Chromium identifier. This is what the
  /// sidebar, the session registry and the recently-closed stack agree on.
  let id: UUID

  /// Page title Chromium last reported; empty until it reports one.
  var title: String
  /// Main-frame URL Chromium last reported.
  var url: URL?
  /// Whether Chromium is currently loading in this tab.
  var isLoading: Bool

  let createdAt: Date
  var lastActivatedAt: Date

  /// Shown when the tab has neither a title nor a URL.
  static let untitled = "New Tab"

  init(
    id: UUID = UUID(),
    title: String = "",
    url: URL? = nil,
    isLoading: Bool = false,
    createdAt: Date = Date(),
    lastActivatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.url = url
    self.isLoading = isLoading
    self.createdAt = createdAt
    self.lastActivatedAt = lastActivatedAt
  }

  /// The label the sidebar shows, in fallback order: the page title, the host of
  /// the committed URL, then "New Tab" (Milestone 3 section 18).
  var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    if let host = url?.host, !host.isEmpty { return host }
    return Self.untitled
  }
}

/// A tab the user closed, kept so ⌘⇧T can reopen it (ARCHITECTURE.md section
/// 42; Milestone 3 section 22).
///
/// Deliberately not a serialised tab: there is no tab identifier here, so a
/// reopened tab can only ever be a *new* BrowserTab with a new identity and a
/// new Chromium browser. Chromium back/forward history, form state, scroll
/// position, cookies and renderer state are not captured - restoring those is
/// later session/persistence work, not Milestone 3.
struct ClosedTabSnapshot: Equatable, Sendable {
  let url: URL?
  let title: String
  /// Index the tab occupied when it closed, so ⌘⇧T can put it back near where
  /// it was when that is still possible.
  let originalIndex: Int
  let closedAt: Date

  init(url: URL?, title: String, originalIndex: Int, closedAt: Date = Date()) {
    self.url = url
    self.title = title
    self.originalIndex = originalIndex
    self.closedAt = closedAt
  }
}
