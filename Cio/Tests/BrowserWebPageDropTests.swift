import AppKit
import CioModel
@testable import CioUI
import XCTest

final class BrowserWebPageDropTests: XCTestCase {
  @MainActor
  func testNativeDragCallbacksPreviewCommitAndClearWithoutSelectingBackgroundTab() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("https://example.com/link", forType: .URL)
    let sender = WebPageDraggingInfo(pasteboard: pasteboard)
    let view = BrowserWebPageDropView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    let original = BrowserTab()
    var workspace = WorkspaceCollection(initialTab: original)
    var previews: [BrowserWebPageDrop.Destination?] = []
    view.destinationAtWindowPoint = { point in
      point.x < 200 ? .tab(before: original.id)
        : (point.x >= 800 ? .rightSplit : nil)
    }
    view.onPreview = { previews.append($0) }
    view.onDrop = { url, destination, _ in
      let incoming = BrowserTab(url: url)
      return workspace.insertDroppedWebPage(incoming, before: original.id,
                                            splittingOnRight: destination == .rightSplit)
    }
    sender.draggingLocation = CGPoint(x: 900, y: 200)
    view.beginPointerDrag(at: CGPoint(x: 600, y: 200))
    XCTAssertEqual(view.draggingEntered(sender), .copy)
    XCTAssertEqual(previews, [.rightSplit])
    sender.draggingLocation = CGPoint(x: 100, y: 200)
    XCTAssertEqual(view.draggingUpdated(sender), .copy)
    XCTAssertTrue(view.prepareForDragOperation(sender))
    XCTAssertTrue(view.performDragOperation(sender))
    view.concludeDragOperation(sender)
    XCTAssertEqual(workspace.allTabs.count, 2)
    XCTAssertEqual(workspace.selectedTabID, original.id)
    XCTAssertNil(workspace.activeSplit)
    XCTAssertEqual(previews, [.rightSplit, .tab(before: original.id), nil])
  }

  @MainActor
  func testNativeDragExitAndInvalidDropClearPreviewWithoutCommitting() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("https://example.com/link", forType: .URL)
    let sender = WebPageDraggingInfo(pasteboard: pasteboard)
    let view = BrowserWebPageDropView()
    var preview: BrowserWebPageDrop.Destination?
    var commits = 0
    view.destinationAtWindowPoint = { _ in .rightSplit }
    view.onPreview = { preview = $0 }
    view.onDrop = { _, _, _ in commits += 1; return true }
    view.beginPointerDrag(at: CGPoint(x: -100, y: 0))
    XCTAssertEqual(view.draggingEntered(sender), .copy)
    view.draggingExited(sender)
    XCTAssertNil(preview)
    view.destinationAtWindowPoint = { _ in .unavailableRightSplit }
    XCTAssertEqual(view.draggingEntered(sender), [])
    XCTAssertFalse(view.performDragOperation(sender))
    XCTAssertEqual(commits, 0)
    pasteboard.clearContents()
    pasteboard.setString("ordinary text", forType: .string)
    XCTAssertFalse(view.prepareForDragOperation(sender))
    XCTAssertFalse(view.performDragOperation(sender))
    XCTAssertEqual(commits, 0)
  }

  @MainActor
  func testRightEdgeSourceRequiresRightwardIntentAndKeepsItAcrossReentry() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("https://example.com/link", forType: .URL)
    let sender = WebPageDraggingInfo(pasteboard: pasteboard)
    let view = BrowserWebPageDropView()
    var preview: BrowserWebPageDrop.Destination?
    view.destinationAtWindowPoint = { $0.x >= 800 ? .rightSplit : nil }
    view.onPreview = { preview = $0 }
    let origin = CGPoint(x: 900, y: 200)
    view.beginPointerDrag(at: origin)
    for point in [origin, CGPoint(x: 880, y: 200), CGPoint(x: 900, y: 400),
                  CGPoint(x: origin.x + BrowserLayout.webPageSplitDragDistance - 1, y: 200)] {
      sender.draggingLocation = point
      XCTAssertEqual(view.draggingUpdated(sender), [])
      XCTAssertNil(preview)
      XCTAssertFalse(view.prepareForDragOperation(sender))
    }
    sender.draggingLocation.x = origin.x + BrowserLayout.webPageSplitDragDistance
    XCTAssertEqual(view.draggingUpdated(sender), .copy)
    XCTAssertEqual(preview, .rightSplit)
    view.draggingExited(sender)
    XCTAssertNil(preview)
    sender.draggingLocation = origin
    XCTAssertEqual(view.draggingEntered(sender), .copy)
    view.draggingEnded(sender)
    view.beginPointerDrag(at: origin)
    XCTAssertEqual(view.draggingEntered(sender), [])
    XCTAssertNil(preview)
    // Sidebar creation does not require moving towards the right edge.
    view.destinationAtWindowPoint = { _ in .tab(before: nil) }
    XCTAssertEqual(view.draggingUpdated(sender), .copy)
  }

  @MainActor
  func testExternalDragUsesFirstEntryAsOriginWithoutImmediateSplit() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("https://example.com/link", forType: .URL)
    let sender = WebPageDraggingInfo(pasteboard: pasteboard)
    let view = BrowserWebPageDropView()
    view.destinationAtWindowPoint = { _ in .rightSplit }
    sender.draggingLocation = CGPoint(x: 850, y: 200)
    XCTAssertEqual(view.draggingEntered(sender), [])
    sender.draggingLocation.x += BrowserLayout.webPageSplitDragDistance
    XCTAssertEqual(view.draggingUpdated(sender), .copy)
  }

  func testSidebarDropCreatesBackgroundTemporaryTab() {
    let original = BrowserTab(url: URL(string: "https://example.com/source")!)
    var workspace = WorkspaceCollection(initialTab: original)
    let incoming = BrowserTab(url: URL(string: "https://example.com/link")!)
    XCTAssertTrue(workspace.insertDroppedWebPage(incoming, before: original.id))
    XCTAssertEqual(workspace.selectedTabID, original.id)
    XCTAssertEqual(workspace.currentTemporaryTabs.map(\.id), [incoming.id, original.id])
    XCTAssertTrue(workspace.currentSpacePinnedTabs.isEmpty)
    XCTAssertTrue(workspace.globalPinnedTabs.isEmpty)
    XCTAssertNil(workspace.activeSplit)
  }

  func testSidebarDropBeforeSplitDoesNotBreakGroupOrderOrSelection() throws {
    let left = BrowserTab(), right = BrowserTab(), incoming = BrowserTab()
    var workspace = WorkspaceCollection(initialTab: left)
    _ = workspace.appendTab(right, in: workspace.selectedSpaceID, select: false)
    _ = workspace.createSplit(with: right.id, on: .right)
    let group = try XCTUnwrap(workspace.activeSplit)
    XCTAssertTrue(workspace.insertDroppedWebPage(incoming, before: right.id))
    XCTAssertEqual(workspace.currentTabIDs, [incoming.id, left.id, right.id])
    XCTAssertEqual(workspace.activeSplit, group)
    XCTAssertEqual(workspace.selectedTabID, right.id)
  }

  func testRightDropCreatesThenExtendsSplitInOrder() throws {
    let original = BrowserTab(), second = BrowserTab(), third = BrowserTab()
    var workspace = WorkspaceCollection(initialTab: original)
    XCTAssertTrue(workspace.insertDroppedWebPage(second, splittingOnRight: true))
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [original.id, second.id])
    XCTAssertEqual(workspace.selectedTabID, second.id)
    XCTAssertTrue(workspace.insertDroppedWebPage(third, splittingOnRight: true))
    XCTAssertEqual(workspace.activeSplit?.tabIDs, [original.id, second.id, third.id])
    XCTAssertEqual(workspace.selectedTabID, third.id)
    let restored = try WorkspaceCollection(restoring: WorkspaceSessionSnapshot(workspace: workspace))
    XCTAssertEqual(restored.activeSplit, workspace.activeSplit)
  }

  func testFullSplitRejectsDropWithoutCreatingTabOrReplacingPane() {
    let original = BrowserTab()
    var workspace = WorkspaceCollection(initialTab: original)
    _ = workspace.insertDroppedWebPage(BrowserTab(), splittingOnRight: true)
    _ = workspace.insertDroppedWebPage(BrowserTab(), splittingOnRight: true)
    let before = workspace
    XCTAssertFalse(workspace.insertDroppedWebPage(BrowserTab(), splittingOnRight: true))
    XCTAssertEqual(workspace, before)
  }

  func testPinnedSourceKeepsBookmarkAndSplitsTemporaryCopy() throws {
    let original = BrowserTab(url: URL(string: "https://example.com/source")!)
    let incoming = BrowserTab(url: URL(string: "https://example.com/link")!)
    var workspace = WorkspaceCollection(initialTab: original)
    _ = workspace.moveTab(original.id, to: .space(workspace.selectedSpaceID))
    XCTAssertTrue(workspace.insertDroppedWebPage(incoming, splittingOnRight: true))
    let split = try XCTUnwrap(workspace.activeSplit)
    XCTAssertNotEqual(split.leftTabID, original.id)
    XCTAssertEqual(workspace.tab(withID: split.leftTabID)?.url, original.url)
    XCTAssertEqual(split.rightTabID, incoming.id)
    XCTAssertEqual(workspace.currentSpacePinnedTabs.map(\.id), [original.id])
    XCTAssertEqual(Set(workspace.currentTemporaryTabs.map(\.id)), Set(split.tabIDs))
  }

  @MainActor
  func testNativeLinkPasteboardPrefersURLOverLabel() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("https://example.com/link?q=1#section", forType: .URL)
    pasteboard.setString("A page title", forType: .string)
    XCTAssertEqual(BrowserWebPageDrop.url(from: pasteboard)?.absoluteString,
                   "https://example.com/link?q=1#section")
  }

  @MainActor
  func testPlainWebAddressAcceptedButOtherPayloadsRejected() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    for raw in ["file:///tmp/page.html", "javascript:alert(1)", "ordinary words", "https:///", "example.com"] {
      pasteboard.clearContents()
      pasteboard.setString(raw, forType: .string)
      XCTAssertNil(BrowserWebPageDrop.url(from: pasteboard), raw)
    }
    pasteboard.clearContents()
    pasteboard.setString(" https://example.com/path\n", forType: .string)
    XCTAssertEqual(BrowserWebPageDrop.url(from: pasteboard)?.absoluteString, "https://example.com/path")
  }

  func testRightFifthUsesCommittedBoundsAndRejectsPointsOutsideContent() {
    let bounds = CGRect(x: 100, y: 56, width: 1000, height: 600)
    XCTAssertFalse(BrowserWebPageDrop.isRightSplitZone(CGPoint(x: 899, y: 100), in: bounds))
    XCTAssertTrue(BrowserWebPageDrop.isRightSplitZone(CGPoint(x: 900, y: 100), in: bounds))
    XCTAssertTrue(BrowserWebPageDrop.isRightSplitZone(CGPoint(x: 1099, y: 100), in: bounds))
    XCTAssertFalse(BrowserWebPageDrop.isRightSplitZone(CGPoint(x: 1101, y: 100), in: bounds))
    XCTAssertFalse(BrowserWebPageDrop.isRightSplitZone(CGPoint(x: 950, y: 55), in: bounds))
    XCTAssertFalse(BrowserWebPageDrop.isRightSplitZone(.zero, in: .zero))
  }
}

@MainActor
private final class WebPageDraggingInfo: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  var draggingLocation = CGPoint.zero
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation = NSDraggingFormation.none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                              classes classArray: [AnyClass],
                              searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                              using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
