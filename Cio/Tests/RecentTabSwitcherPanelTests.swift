import AppKit
import CioUI
import XCTest

@MainActor
final class RecentTabSwitcherPanelTests: XCTestCase {
  func testCardsHaveEqualOuterInsetsWithoutFooterAtEveryCandidateCount() throws {
    for count in 1...5 {
      for width: CGFloat in [480, 1200] {
        let layout = RecentTabSwitcherLayout(count: count, availableWidth: width)
        let first = try XCTUnwrap(layout.cardFrames.first)
        let last = try XCTUnwrap(layout.cardFrames.last)
        XCTAssertEqual(first.minX, first.minY, accuracy: 0.001)
        XCTAssertEqual(first.minX, layout.size.width - last.maxX, accuracy: 0.001)
        XCTAssertEqual(first.minY, layout.size.height - last.maxY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(layout.size.width, width)
      }
    }
  }

  func testFiveCandidatePanelFitsWindowAndCannotStealNativeEditorFocus() {
    _ = NSApplication.shared
    let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                          styleMask: [.titled], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    defer { parent.close() }
    let editor = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
    parent.contentView?.addSubview(editor)
    parent.makeFirstResponder(editor)
    let responder = parent.firstResponder
    let panel = RecentTabSwitcherPanel { _ in XCTFail("Layout must not activate a candidate") }
    defer { panel.window.close() }
    let ids = (0..<5).map { _ in UUID() }
    panel.update(candidates: ids.map {
      RecentTabCandidate(id: $0, title: "Page", host: "example.com", favicon: nil, preview: nil)
    }, selectedID: ids[1])
    panel.layout(in: parent)
    XCTAssertEqual(panel.window.frame.midX, parent.frame.midX, accuracy: 0.5)
    XCTAssertEqual(panel.window.frame.midY, parent.frame.midY, accuracy: 0.5)
    XCTAssertTrue(parent.frame.contains(panel.window.frame))
    XCTAssertFalse(panel.window.canBecomeKey)
    XCTAssertFalse(panel.window.canBecomeMain)
    XCTAssertTrue(parent.firstResponder === responder)
  }
}
