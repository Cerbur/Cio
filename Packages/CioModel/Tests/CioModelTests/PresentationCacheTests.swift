import CioModel
import XCTest

final class PresentationCacheTests: XCTestCase {
  func testReadHitProtectsEntryAndBothBudgetsEvictLeastRecentlyUsed() {
    var cache = BoundedLRUCache<String, Int>(countLimit: 3, costLimit: 6)
    cache.insert(1, for: "a", cost: 2)
    cache.insert(2, for: "b", cost: 2)
    cache.insert(3, for: "c", cost: 2)
    XCTAssertEqual(cache.value(for: "a"), 1)
    cache.insert(4, for: "d", cost: 3)
    XCTAssertNil(cache.value(for: "b"))
    XCTAssertNil(cache.value(for: "c"))
    XCTAssertEqual(cache.value(for: "a"), 1)
    XCTAssertEqual(cache.totalCost, 5)
  }

  func testOverwriteOversizeRemovalAndNegativeEntriesRemainBounded() {
    var cache = BoundedLRUCache<Int, Bool>(countLimit: 2, costLimit: 4)
    cache.insert(true, for: 1, cost: 4)
    cache.insert(false, for: 1, cost: 1)
    XCTAssertEqual(cache.totalCost, 1)
    cache.insert(false, for: 2, cost: 0)
    cache.insert(false, for: 3, cost: 0)
    XCTAssertEqual(cache.count, 2)
    XCTAssertEqual(cache.totalCost, 0)
    cache.insert(true, for: 3, cost: 5)
    XCTAssertNil(cache.value(for: 3))
    cache.remove(2)
    XCTAssertEqual(cache.count, 0)
  }

  func testTitleLimitPreservesUnicodeAndOversizeArtworkIsDiscarded() {
    let title = String(repeating: "🌍中", count: 3000)
    let tab = BrowserTab(title: title, faviconData: Data(repeating: 1, count: BrowserPresentationLimits.faviconBytes + 1))
    XCTAssertLessThanOrEqual(tab.title.utf8.count, BrowserPresentationLimits.titleBytes)
    XCTAssertTrue(title.hasPrefix(tab.title))
    XCTAssertFalse(tab.title.contains("�"))
    XCTAssertNil(tab.faviconData)
  }

  func testWorkspaceAndSnapshotArtworkHaveCountAndByteBudgetsWithoutRemovingTabs() throws {
    var workspace = WorkspaceCollection(initialTab: BrowserTab(title: "Current", faviconData: Data([1])))
    let current = try XCTUnwrap(workspace.selectedTabID)
    var tabs: [BrowserTab] = []
    for index in 0..<140 {
      let tab = BrowserTab(title: "Page \(index)", faviconData: Data([1]),
                           lastActivatedAt: Date(timeIntervalSince1970: Double(index)))
      tabs.append(tab)
      XCTAssertTrue(workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false))
    }
    workspace.trimPresentationCache()
    XCTAssertEqual(workspace.allTabs.count, 141)
    XCTAssertEqual(workspace.allTabs.compactMap(\.faviconData).count, 128)
    XCTAssertNotNil(workspace.tab(withID: current)?.faviconData)
    XCTAssertNil(workspace.tab(withID: tabs[0].id)?.faviconData)
    for id in workspace.allTabIDs {
      var tab = try XCTUnwrap(workspace.tab(withID: id))
      tab.faviconData = Data(repeating: 1, count: BrowserPresentationLimits.faviconBytes)
      _ = workspace.refresh(tab)
    }
    let snapshot = WorkspaceSessionSnapshot(workspace: workspace)
    let artwork = snapshot.spaces.flatMap(\.tabs).compactMap(\.faviconData)
    XCTAssertEqual(artwork.reduce(0) { $0 + $1.count }, BrowserPresentationLimits.faviconTotalBytes)
    let restored = try WorkspaceCollection(restoring: snapshot)
    XCTAssertEqual(restored.allTabIDs, workspace.allTabIDs)
    XCTAssertEqual(restored.selectedTabID, current)
  }
}
