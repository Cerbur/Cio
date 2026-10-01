//
//  BrowserSpace.swift
//  NativeBrowser
//
//  CEF-independent logical Space identity and tab membership.
//

import Foundation

/// A logical group of tabs.
///
/// A Space contains only domain identity and ordering. Runtime objects and
/// platform views deliberately do not appear here so the workspace rules can
/// be tested without starting CEF.
struct BrowserSpace: Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var tabIDs: [UUID]
  var pinnedTabIDs: [UUID]
  var selectedTabID: UUID?
  /// Opening/activation history, oldest first. Closed background tabs may
  /// leave stale IDs here until a selected close consumes them.
  var stableTabStack: [UUID]
  var splitGroups: [BrowserSplitLayout]

  init(
    id: UUID = UUID(),
    name: String,
    tabIDs: [UUID] = [],
    pinnedTabIDs: [UUID] = [],
    selectedTabID: UUID? = nil,
    stableTabStack: [UUID] = [],
    splitGroups: [BrowserSplitLayout] = []
  ) {
    self.id = id
    self.name = name
    self.tabIDs = tabIDs
    self.pinnedTabIDs = pinnedTabIDs
    self.selectedTabID = selectedTabID
    self.stableTabStack = stableTabStack
    self.splitGroups = splitGroups
  }
}
