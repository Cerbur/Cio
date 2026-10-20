import Foundation

/// One switcher flight freezes MRU order until commit; highlighting never
/// activates a browser or changes the next candidate's position.
public struct RecentTabSelection: Equatable, Sendable {
  public private(set) var candidateIDs: [UUID]
  public private(set) var selectedID: UUID?

  public init(candidateIDs: [UUID], currentID: UUID?, forward: Bool) {
    var seen = Set<UUID>()
    self.candidateIDs = Array(candidateIDs.filter { seen.insert($0).inserted }.prefix(5))
    selectedID = currentID.flatMap { self.candidateIDs.contains($0) ? $0 : nil }
      ?? (forward ? self.candidateIDs.last : self.candidateIDs.first)
    advance(forward: forward)
  }

  public mutating func advance(forward: Bool) {
    guard !candidateIDs.isEmpty else { selectedID = nil; return }
    let index = selectedID.flatMap { candidateIDs.firstIndex(of: $0) } ?? 0
    selectedID = candidateIDs[(index + (forward ? 1 : candidateIDs.count - 1)) % candidateIDs.count]
  }

  public mutating func select(_ id: UUID) {
    if candidateIDs.contains(id) { selectedID = id }
  }

  public mutating func retainAvailable(_ ids: Set<UUID>) {
    let oldIndex = selectedID.flatMap { candidateIDs.firstIndex(of: $0) } ?? 0
    candidateIDs.removeAll { !ids.contains($0) }
    if let selectedID, candidateIDs.contains(selectedID) { return }
    selectedID = candidateIDs.isEmpty ? nil : candidateIDs[min(oldIndex, candidateIDs.count - 1)]
  }
}
