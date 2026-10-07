//
//  BrowserSpace.swift
//  Cio
//
//  CEF-independent logical Space identity and tab membership.
//

import Foundation

/// Shared by the Space row and its page indicator; future icon pickers can
/// supply either an emoji or a native SF Symbol without changing those views.
public enum BrowserSpaceIcon: Codable, Equatable, Sendable {
  case emoji(String)
  case systemImage(String)

  public static let placeholder = Self.emoji("🧸")
}

/// A logical group of tabs.
///
/// A Space contains only domain identity and ordering. Runtime objects and
/// platform views deliberately do not appear here so the workspace rules can
/// be tested without starting CEF.
public struct BrowserSpace: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var icon: BrowserSpaceIcon
  public var tabIDs: [UUID]
  public var pinnedTabIDs: [UUID]
  public var selectedTabID: UUID?
  /// Opening/activation history, oldest first. Closed background tabs may
  /// leave stale IDs here until a selected close consumes them.
  public var stableTabStack: [UUID]
  public var splitGroups: [BrowserSplitLayout]

  public init(
    id: UUID = UUID(),
    name: String,
    icon: BrowserSpaceIcon = .placeholder,
    tabIDs: [UUID] = [],
    pinnedTabIDs: [UUID] = [],
    selectedTabID: UUID? = nil,
    stableTabStack: [UUID] = [],
    splitGroups: [BrowserSplitLayout] = []
  ) {
    self.id = id
    self.name = name
    self.icon = icon
    self.tabIDs = tabIDs
    self.pinnedTabIDs = pinnedTabIDs
    self.selectedTabID = selectedTabID
    self.stableTabStack = stableTabStack
    self.splitGroups = splitGroups
  }
}
