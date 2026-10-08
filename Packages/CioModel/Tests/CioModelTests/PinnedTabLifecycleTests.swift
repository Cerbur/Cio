import CioModel
import XCTest

final class PinnedTabLifecycleTests: XCTestCase {
  private let pinnedURL = URL(string: "https://example.com/pinned?value=1#anchor")!
  private let navigatedURL = URL(string: "https://example.com/elsewhere?value=2#later")!

  private func roundTrip(_ workspace: WorkspaceCollection) throws -> WorkspaceCollection {
    let data = try JSONEncoder().encode(WorkspaceSessionSnapshot(workspace: workspace))
    return try WorkspaceCollection(restoring: JSONDecoder().decode(WorkspaceSessionSnapshot.self, from: data))
  }

  func testSpacePinClosesToBookmarkAcrossNavigationReorderAndRelaunch() throws {
    var workspace = WorkspaceCollection(initialTab: BrowserTab(url: pinnedURL))
    let pin = workspace.selectedTabID!
    let space = workspace.selectedSpaceID
    XCTAssertTrue(workspace.moveTab(pin, to: .space(space)))
    for index in 1...5 {
      var tab = workspace.tab(withID: pin)!
      tab.url = URL(string: "https://example.com/hop/\(index)")!
      XCTAssertTrue(workspace.refresh(tab))
    }
    XCTAssertTrue(workspace.moveTab(pin, to: .space(space)))
    XCTAssertEqual(workspace.tab(withID: pin)?.spacePinURL, pinnedURL)
    workspace = try roundTrip(workspace)
    XCTAssertEqual(workspace.close(pin, reason: .userClosed).outcome, .retainedLast)
    XCTAssertEqual(workspace.currentSpacePinnedTabs.map(\.id), [pin])
    XCTAssertEqual(workspace.tab(withID: pin)?.url, pinnedURL)
    XCTAssertEqual(workspace.tab(withID: pin)?.isSpacePinClosed, true)
    XCTAssertTrue(workspace.recentlyClosed.isEmpty)
    XCTAssertNil(workspace.selectedTabID)
    // Late callbacks from the closing renderer cannot overwrite the bookmark.
    XCTAssertFalse(workspace.refresh(BrowserTab(id: pin, url: navigatedURL)))
    workspace = try roundTrip(workspace)
    XCTAssertNil(workspace.selectedTabID)
    XCTAssertTrue(workspace.selectTab(id: pin))
    XCTAssertEqual(workspace.selectedTab?.url, pinnedURL)
    XCTAssertEqual(workspace.selectedTab?.isSpacePinClosed, false)
  }

  func testTopPinsCollapseInActivationOrderAndKeepLatestURL() throws {
    var workspace = WorkspaceCollection(initialTab: BrowserTab(url: pinnedURL))
    let page = workspace.selectedTabID!
    let first = BrowserTab(url: pinnedURL)
    let second = BrowserTab(url: pinnedURL)
    for tab in [first, second] {
      XCTAssertTrue(workspace.appendTab(tab, in: workspace.selectedSpaceID, select: false))
      XCTAssertTrue(workspace.moveTab(tab.id, to: .global))
    }
    XCTAssertTrue(workspace.selectTab(id: first.id))
    XCTAssertTrue(workspace.selectTab(id: second.id))
    XCTAssertTrue(workspace.refresh(BrowserTab(id: second.id, title: "Latest", url: navigatedURL)))
    XCTAssertEqual(workspace.close(second.id, reason: .userClosed).outcome, .retainedSelectionMoved(to: first.id))
    XCTAssertEqual(workspace.close(first.id, reason: .userClosed).outcome, .retainedSelectionMoved(to: page))
    XCTAssertEqual(workspace.globalPinnedTabIDs, [first.id, second.id])
    XCTAssertTrue(workspace.recentlyClosed.isEmpty)
    workspace = try roundTrip(workspace)
    XCTAssertTrue(workspace.selectTab(id: second.id))
    XCTAssertEqual(workspace.selectedTab?.url, navigatedURL)
  }

  func testClosingAllPagesLeavesPinsAvailableWithoutSelectingThem() throws {
    var workspace = WorkspaceCollection(initialTab: BrowserTab(url: pinnedURL))
    let space = workspace.selectedSpaceID
    let pin = workspace.selectedTabID!
    XCTAssertTrue(workspace.moveTab(pin, to: .space(space)))
    XCTAssertEqual(workspace.close(pin, reason: .userClosed).outcome, .retainedLast)
    let top = BrowserTab(url: navigatedURL)
    XCTAssertTrue(workspace.appendTab(top, in: space, select: true))
    XCTAssertTrue(workspace.moveTab(top.id, to: .global))
    XCTAssertEqual(workspace.close(top.id, reason: .userClosed).outcome, .retainedLast)
    let temporary = BrowserTab(url: navigatedURL)
    XCTAssertTrue(workspace.appendTab(temporary, in: space, select: true))
    XCTAssertEqual(workspace.close(temporary.id, reason: .userClosed).outcome, .removedLast)
    XCTAssertNil(workspace.selectedTabID)
    XCTAssertEqual(workspace.allTabs.count, 2)
    workspace = try roundTrip(workspace)
    XCTAssertNil(workspace.selectedTabID)
    XCTAssertTrue(workspace.selectTab(id: top.id))
    XCTAssertEqual(workspace.close(top.id, reason: .userClosed).outcome, .retainedLast)
    XCTAssertTrue(workspace.selectTab(id: pin))
    XCTAssertEqual(workspace.selectedTab?.url, pinnedURL)
  }

  func testEntirelyEmptySpaceRestoresAndCanOpenAnotherTab() throws {
    var workspace = WorkspaceCollection(initialTab: BrowserTab(url: pinnedURL))
    let result = workspace.close(workspace.selectedTabID!, reason: .userClosed)
    XCTAssertFalse(result.needsReplacementTab)
    XCTAssertTrue(workspace.allTabs.isEmpty)
    workspace = try roundTrip(workspace)
    XCTAssertNil(workspace.selectedTabID)
    XCTAssertTrue(workspace.allTabs.isEmpty)
    let new = BrowserTab(url: navigatedURL)
    XCTAssertTrue(workspace.appendTab(new, in: workspace.selectedSpaceID, select: true))
    XCTAssertEqual(workspace.selectedTabID, new.id)
  }

  func testRepinningCapturesNewAddressAndClosedSpacePinDoesNotWakeOnSpaceSwitch() throws {
    var workspace = WorkspaceCollection(initialTab: BrowserTab(url: pinnedURL))
    let pin = workspace.selectedTabID!
    let owner = workspace.selectedSpaceID
    XCTAssertTrue(workspace.moveTab(pin, to: .space(owner)))
    XCTAssertTrue(workspace.moveTab(pin, to: .temporary(owner)))
    XCTAssertTrue(workspace.refresh(BrowserTab(id: pin, url: navigatedURL)))
    XCTAssertTrue(workspace.moveTab(pin, to: .space(owner)))
    _ = workspace.close(pin, reason: .userClosed)
    let other = workspace.createSpace(initialTab: BrowserTab(url: pinnedURL))!
    XCTAssertTrue(workspace.selectSpace(id: owner))
    XCTAssertNil(workspace.selectedTabID)
    XCTAssertEqual(workspace.tab(withID: pin)?.spacePinURL, navigatedURL)
    XCTAssertTrue(workspace.selectSpace(id: other))
    XCTAssertTrue(workspace.selectSpace(id: owner))
    XCTAssertNil(workspace.selectedTabID)
  }
}
