//
//  HistoryModels.swift
//  Cio
//
//  CEF-independent browsing history domain types.
//

import Foundation

public struct HistoryEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let url: URL
  public var title: String
  public var visitCount: Int
  public var firstVisitedAt: Date
  public var lastVisitedAt: Date
}

public enum HistoryURLPolicy {
  public static func isRecordable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  static func usefulTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
