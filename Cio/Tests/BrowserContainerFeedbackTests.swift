import AppKit
import CioEngine
import CioModel
@testable import CioUI
import SwiftUI
import XCTest

final class BrowserContainerFeedbackTests: XCTestCase {
  @MainActor
  func testPageContainerOwnsCompressionReplacementAndReentryFeedback() {
    withHost { host in
      var feedback: [BrowserDragHaptics.Feedback] = []
      host.containerFeedback = { feedback.append($0) }
      host.previewSplit(at: .init(side: .right))
      XCTAssertTrue(feedback.isEmpty, "An empty container has nothing to compress")
      host.previewSplit(at: nil)
      let id = UUID()
      host.present(containers: [id: BrowserSurfaceAttachment(surface: FeedbackTestSurface())], selectedTabID: id)
      host.previewSplit(at: .init(side: .right))
      host.previewSplit(at: .init(side: .right))
      host.layout()
      XCTAssertEqual(feedback, [.compression])
      host.previewSplit(at: .init(side: .right), incomingPaneCount: 2)
      XCTAssertEqual(feedback, [.compression, .compression])
      host.previewSplit(at: nil)
      host.previewSplit(at: .init(side: .middle))
      host.previewSplit(at: .init(side: .middle))
      host.layout()
      XCTAssertEqual(feedback, [.compression, .compression, .replacement])
      host.previewSplit(at: .init(side: .right))
      host.previewSplit(at: nil)
      host.previewSplit(at: .init(side: .right))
      XCTAssertEqual(feedback, [.compression, .compression, .replacement, .compression, .compression])
    }
  }

  @MainActor
  func testSplitContainerOwnsPaneReplacementAndReorderingFeedback() {
    withHost { host in
      var feedback: [BrowserDragHaptics.Feedback] = []
      host.containerFeedback = { feedback.append($0) }
      let left = UUID(), right = UUID(), middle = UUID()
      let attachments = Dictionary(uniqueKeysWithValues: [left, middle, right].map {
        ($0, BrowserSurfaceAttachment(surface: FeedbackTestSurface()))
      })
      var split = BrowserSplitLayout(leftTabID: left, rightTabID: right)
      host.present(containers: attachments, selectedTabID: left, split: split)
      host.previewSplit(at: .init(side: .right))
      host.previewSplit(at: .init(side: .right, replacesPane: true))
      host.previewSplit(at: .init(side: .right, replacesPane: true))
      host.previewSplit(at: .init(side: .left, replacesPane: true))
      host.layout()
      XCTAssertEqual(feedback, [.compression, .replacement, .replacement])
      host.previewSplit(at: nil)
      host.previewPaneDrag(left, index: 0)
      XCTAssertEqual(feedback.count, 3, "Lifting in place does not displace neighbours")
      host.previewPaneDrag(left, index: 1)
      host.previewPaneDrag(left, index: 1)
      host.layout()
      host.previewPaneDrag(left, index: 0)
      host.previewPaneDrag(nil)
      XCTAssertEqual(feedback, [.compression, .replacement, .replacement, .compression, .compression])
      split = split.placingPane(middle, on: .middle)
      host.present(containers: attachments, selectedTabID: middle, split: split)
      host.previewSplit(at: .init(side: .right))
      XCTAssertEqual(feedback.last, .replacement, "A full group's preview replaces its target pane")
      XCTAssertEqual(feedback.count, 6)
    }
  }

  @MainActor
  func testSidebarContainerEmitsFeedbackForWebSlotsAndOrdinaryReordering() {
    _ = NSApplication.shared
    let space = UUID(), first = UUID(), second = UUID(), incoming = UUID()
    let drag = SidebarTabDrag()
    drag.reduceMotion = true
    var feedback: [BrowserDragHaptics.Feedback] = []
    func panel(_ ids: [UUID], drop: SpaceTabPanelRow.DropPosition? = nil) -> some View {
      let rows = SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [], temporaryIDs: ids,
        groups: [], drop: drop)
      return SpaceTabPanel(rows: rows, drag: drag, containerFeedback: { feedback.append($0) }) { _ in
        Color.clear
      } tabContent: { _, _ in
        Color.clear
      } rowBackground: { _ in
        Color.clear
      }
    }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: panel([first, second]))
    window.contentView = host
    func flush() {
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    flush()
    XCTAssertTrue(feedback.isEmpty, "Mounting a container is silent")
    host.rootView = panel([first, second], drop: .init(tier: .temporary(space), before: first))
    flush()
    XCTAssertEqual(feedback, [.compression])
    host.rootView = panel([first, second], drop: .init(tier: .temporary(space), before: first))
    flush()
    XCTAssertEqual(feedback, [.compression])
    host.rootView = panel([first, second], drop: .init(tier: .temporary(space), before: second))
    flush()
    XCTAssertEqual(feedback, [.compression, .compression])
    host.rootView = panel([first, incoming, second])
    flush()
    XCTAssertEqual(feedback.count, 2, "Replacing a gap with its tab must not pulse again")
    host.rootView = panel([second, incoming, first])
    flush()
    XCTAssertEqual(feedback, [.compression, .compression, .compression])
    host.rootView = panel([incoming, first])
    flush()
    XCTAssertEqual(feedback.count, 3, "Removing a source alone is not compression")
  }

  @MainActor
  func testEmptyTierEndSlotAndCancelledSlotDoNotProduceCompressionFeedback() {
    let space = UUID(), tab = UUID()
    func snapshot(_ ids: [UUID], before: UUID? = nil, gap: Bool = false) -> SidebarTabPanelLayout.FeedbackSnapshot {
      SidebarTabPanelLayout(rows: SpaceTabPanelRow.make(spaceID: space, pinnedIDs: [],
        temporaryIDs: ids, groups: [], drop: gap ? .init(tier: .temporary(space), before: before) : nil))
        .feedbackSnapshot
    }
    XCTAssertNil(snapshot([], gap: true).feedback(from: snapshot([])))
    XCTAssertNil(snapshot([tab], gap: true).feedback(from: snapshot([tab])))
    let reserved = snapshot([tab], before: tab, gap: true)
    XCTAssertEqual(reserved.feedback(from: snapshot([tab])), .compression)
    XCTAssertNil(snapshot([tab]).feedback(from: reserved))
    XCTAssertNil(reserved.feedback(from: reserved))
  }

  @MainActor
  private func withHost(_ check: (BrowserSurfaceHostView) -> Void) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 700),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = BrowserSurfaceHostView(frame: window.contentView!.bounds)
    window.contentView = host
    check(host)
  }
}

@MainActor
private final class FeedbackTestSurface: BrowserNativeSurface {
  let nativeView = NSView(frame: .zero)
  var browserSession: (any BrowserSessionProtocol)? { nil }
  func setSurfaceVisible(_ visible: Bool) {}
}
