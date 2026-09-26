//
//  WorkspaceSessionSnapshot.swift
//  NativeBrowser
//
//  Stable, CEF-free persistence schema for the open workspace.
//
//  This is deliberately separate from BrowserTab and BrowserSpace. Those
//  types are the live domain model and contain transient runtime metadata;
//  this schema is the small durable contract that can survive a relaunch.
//

import Foundation

/// The only supported on-disk workspace snapshot version.
struct WorkspaceSessionSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let selectedSpaceID: UUID
  let spaces: [PersistedSpace]
  var globalPinnedTabIDs: [UUID] = []
  var selectedGlobalTabID: UUID? = nil

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    selectedSpaceID: UUID,
    spaces: [PersistedSpace]
  ) {
    self.schemaVersion = schemaVersion
    self.selectedSpaceID = selectedSpaceID
    self.spaces = spaces
  }

  /// Builds the durable projection of the live domain graph. Runtime-only
  /// state such as loading, navigation capabilities and recently-closed tabs
  /// cannot enter this value by construction.
  init(workspace: WorkspaceCollection) {
    schemaVersion = Self.currentSchemaVersion
    selectedSpaceID = workspace.selectedSpaceID
    globalPinnedTabIDs = workspace.globalPinnedTabIDs
    selectedGlobalTabID = workspace.selectedGlobalTabID
    spaces = workspace.spaces.map { space in
      let tabs = space.tabIDs.compactMap { workspace.tab(withID: $0) }.map(PersistedTab.init)
      return PersistedSpace(
        id: space.id,
        name: space.name,
        selectedTabID: space.selectedTabID,
        tabs: tabs,
        pinnedTabIDs: space.pinnedTabIDs)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, selectedSpaceID, spaces, globalPinnedTabIDs, selectedGlobalTabID
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    selectedSpaceID = try values.decode(UUID.self, forKey: .selectedSpaceID)
    spaces = try values.decode([PersistedSpace].self, forKey: .spaces)
    globalPinnedTabIDs = try values.decodeIfPresent([UUID].self, forKey: .globalPinnedTabIDs) ?? []
    selectedGlobalTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedGlobalTabID)
  }
}

/// One persisted Space, in the order in which it appears in the `spaces`
/// array.
struct PersistedSpace: Codable, Equatable, Sendable {
  let id: UUID
  let name: String
  let selectedTabID: UUID?
  let tabs: [PersistedTab]
  var pinnedTabIDs: [UUID] = []

  init(id: UUID, name: String, selectedTabID: UUID?, tabs: [PersistedTab], pinnedTabIDs: [UUID] = []) {
    self.id = id
    self.name = name
    self.selectedTabID = selectedTabID
    self.tabs = tabs
    self.pinnedTabIDs = pinnedTabIDs
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, selectedTabID, tabs, pinnedTabIDs
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    selectedTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedTabID)
    tabs = try values.decode([PersistedTab].self, forKey: .tabs)
    pinnedTabIDs = try values.decodeIfPresent([UUID].self, forKey: .pinnedTabIDs) ?? []
  }
}

/// One persisted tab, in the order in which it appears in its Space's `tabs`
/// array. URLs are strings in the stable file format so the exact committed
/// URL, including query and fragment, is retained without serializing any
/// runtime navigation object.
struct PersistedTab: Codable, Equatable, Sendable {
  let id: UUID
  let title: String
  let url: String?
  let createdAt: Date
  let lastActivatedAt: Date

  init(
    id: UUID,
    title: String,
    url: String?,
    createdAt: Date,
    lastActivatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.url = url
    self.createdAt = createdAt
    self.lastActivatedAt = lastActivatedAt
  }

  init(tab: BrowserTab) {
    self.init(
      id: tab.id,
      title: tab.title,
      url: tab.url?.absoluteString,
      createdAt: tab.createdAt,
      lastActivatedAt: tab.lastActivatedAt)
  }
}

/// A deliberately non-sensitive validation error. Its description is safe to
/// put in diagnostics because it never includes the snapshot JSON or a URL
/// value supplied by the file.
enum WorkspaceSessionSnapshotError: Error, Equatable, Sendable, CustomStringConvertible {
  case unsupportedSchema
  case noSpaces
  case duplicateSpaceID
  case emptySpaceName
  case emptySpace
  case duplicateTabID
  case invalidURL
  case missingSelectedSpace
  case missingSelectedTab
  case selectedTabNotInSpace
  case invalidPinnedTabs

  var description: String {
    switch self {
    case .unsupportedSchema: return "unsupported schema version"
    case .noSpaces: return "snapshot contains no Spaces"
    case .duplicateSpaceID: return "duplicate Space identity"
    case .emptySpaceName: return "Space has an empty name"
    case .emptySpace: return "Space contains no tabs"
    case .duplicateTabID: return "duplicate tab identity"
    case .invalidURL: return "tab contains an invalid URL"
    case .missingSelectedSpace: return "selected Space does not exist"
    case .missingSelectedTab: return "Space has no selected tab"
    case .selectedTabNotInSpace: return "selected tab is not a member of its Space"
    case .invalidPinnedTabs: return "pinned tab membership or selection is invalid"
    }
  }
}
