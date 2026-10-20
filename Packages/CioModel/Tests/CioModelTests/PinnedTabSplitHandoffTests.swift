import CioModel
import XCTest

final class PinnedTabSplitHandoffTests: XCTestCase {
  func testCopiesIdentifyBothPinsAcrossTiersAndDropSides() throws {
    for existingTier in 0...2 {
      for incomingTier in 0...2 {
        for side in [BrowserSplitLayout.Side.left, .right] {
          let existing = BrowserTab(title: "Existing", url: URL(string: "https://example.com/same"), isLoading: true)
          let incoming = BrowserTab(title: "Incoming", url: existing.url, isLoading: true)
          var workspace = WorkspaceCollection(initialTab: existing)
          let space = workspace.selectedSpaceID
          let tiers: [WorkspaceCollection.TabTier] = [.temporary(space), .space(space), .global]
          XCTAssertTrue(workspace.appendTab(incoming, in: space, select: false))
          if existingTier != 0 { XCTAssertTrue(workspace.moveTab(existing.id, to: tiers[existingTier])) }
          if incomingTier != 0 { XCTAssertTrue(workspace.moveTab(incoming.id, to: tiers[incomingTier])) }
          let pins = workspace.globalPinnedTabIDs + workspace.selectedSpace!.pinnedTabIDs
          var copies: [UUID: UUID] = [:]
          XCTAssertTrue(workspace.createSplit(with: incoming.id, at: .init(side: side), pinnedTabCopies: &copies))
          XCTAssertEqual(Set(copies.keys), Set(pins))
          let split = try XCTUnwrap(workspace.activeSplit)
          let existingID = copies[existing.id] ?? existing.id
          let incomingID = copies[incoming.id] ?? incoming.id
          XCTAssertEqual(split.tabIDs, side == .left ? [incomingID, existingID] : [existingID, incomingID])
          for source in [existing, incoming] {
            let destination = copies[source.id] ?? source.id
            XCTAssertEqual(workspace.tab(withID: destination)?.title, source.title,
              "Equal URLs must still hand off the correct source page")
            XCTAssertEqual(workspace.tab(withID: destination)?.isLoading, true)
            if copies[source.id] != nil {
              XCTAssertEqual(workspace.tab(withID: source.id)?.isLoading, false)
              XCTAssertFalse(split.contains(source.id))
            }
          }
          XCTAssertEqual(workspace.globalPinnedTabIDs + workspace.selectedSpace!.pinnedTabIDs, pins)
          XCTAssertTrue(workspace.recentlyClosed.isEmpty)
          XCTAssertTrue(workspace.validateInvariants())
        }
      }
    }
  }

  func testPinnedGroupReplacementTransfersOnlySurvivingPanes() throws {
    let first = BrowserTab(title: "First"), second = BrowserTab(title: "Second"), incoming = BrowserTab(title: "Incoming")
    var workspace = WorkspaceCollection(initialTab: first)
    let space = workspace.selectedSpaceID
    XCTAssertTrue(workspace.appendTab(second, in: space, select: false))
    XCTAssertTrue(workspace.appendTab(incoming, in: space, select: false))
    XCTAssertTrue(workspace.createSplit(with: second.id, on: .right))
    XCTAssertTrue(workspace.moveSplitGroup(containing: first.id, to: .space(space)))
    let original = try XCTUnwrap(workspace.activeSplit)
    var copies: [UUID: UUID] = [:]
    XCTAssertTrue(workspace.createSplit(with: incoming.id,
      at: .init(side: .right, replacesPane: true), pinnedTabCopies: &copies))
    XCTAssertEqual(Set(copies.keys), [first.id])
    XCTAssertEqual(workspace.splitGroup(containing: first.id), original)
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [try XCTUnwrap(copies[first.id]), incoming.id])
    XCTAssertTrue(workspace.validateInvariants())
  }

  func testWebPageDropAlsoReportsTheSelectedPinsTemporaryIdentity() throws {
    let pin = BrowserTab(title: "Pin")
    var workspace = WorkspaceCollection(initialTab: pin)
    XCTAssertTrue(workspace.moveTab(pin.id, to: .global))
    let incoming = BrowserTab(title: "Dropped")
    var copies: [UUID: UUID] = [:]
    XCTAssertTrue(workspace.insertDroppedWebPage(incoming, splittingOnRight: true, pinnedTabCopies: &copies))
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [try XCTUnwrap(copies[pin.id]), incoming.id])
    XCTAssertEqual(workspace.globalPinnedTabIDs, [pin.id])
  }

  func testRejectedAndSelectionOnlyDropsDoNotReportHandoffs() {
    let pin = BrowserTab(title: "Pin"), incoming = BrowserTab(title: "Incoming")
    var workspace = WorkspaceCollection(initialTab: pin)
    XCTAssertTrue(workspace.moveTab(pin.id, to: .global))
    XCTAssertTrue(workspace.appendTab(incoming, in: workspace.selectedSpaceID, select: false))
    let before = workspace
    var copies = [UUID(): UUID()]
    XCTAssertFalse(workspace.createSplit(with: UUID(), at: .init(side: .right), pinnedTabCopies: &copies))
    XCTAssertTrue(copies.isEmpty)
    XCTAssertEqual(workspace, before)
    XCTAssertTrue(workspace.createSplit(with: incoming.id, at: .init(side: .middle), pinnedTabCopies: &copies))
    XCTAssertTrue(copies.isEmpty)
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(workspace.selectedTabID, incoming.id)
  }
}
