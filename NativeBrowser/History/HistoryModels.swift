//
//  HistoryModels.swift
//  NativeBrowser
//
//  CEF-independent browsing history domain types.
//

import Foundation

struct HistoryEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  let url: URL
  var title: String
  var visitCount: Int
  var firstVisitedAt: Date
  var lastVisitedAt: Date
}

enum HistoryURLPolicy {
  static func isRecordable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  static func usefulTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
