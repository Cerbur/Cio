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

  init(
    id: UUID = UUID(),
    name: String,
    tabIDs: [UUID] = [],
    pinnedTabIDs: [UUID] = [],
    selectedTabID: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.tabIDs = tabIDs
    self.pinnedTabIDs = pinnedTabIDs
    self.selectedTabID = selectedTabID
  }
}
