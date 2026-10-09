import AppKit
import CioEngine
import CioModel
@testable import CioUI
import XCTest

final class BrowserSurfaceDropTests: XCTestCase {
  @MainActor
  func testPreviewAndInterruptedReturnNeverResizeTheLiveDocument() throws {
    try withHost { host in
      let id = UUID(), surface = DropTestSurface()
      host.present(containers: [id: BrowserSurfaceAttachment(surface: surface)], selectedTabID: id)
      let original = surface.nativeView.frame
      surface.clearRenderSizes()
      for side in [BrowserSplitLayout.Side.right, .left, .right] {
        host.previewSplit(at: .init(side: side))
        host.layout()
        XCTAssertEqual(surface.nativeView.frame, original)
        // Interrupt at a 120 Hz frame boundary, then re-enter during restore.
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        host.previewSplit(at: nil)
        host.layout()
        XCTAssertEqual(surface.nativeView.frame, original)
      }
      sampleLayout(host, duration: AnimationValues.SplitPages.layoutDuration * 2) {
        XCTAssertEqual(surface.nativeView.frame, original)
      }
      XCTAssertTrue(surface.renderSizes.isEmpty, "Hover/cancellation must never request a Chromium resize")
    }
  }

  @MainActor
  func testTwoPanePreviewFreezesBothDocumentsAndCommitResizesOnce() throws {
    try withHost { host in
      let leftID = UUID(), rightID = UUID(), incomingID = UUID()
      let left = DropTestSurface(), right = DropTestSurface(), incoming = DropTestSurface()
      let attachments = [leftID: BrowserSurfaceAttachment(surface: left),
                         rightID: BrowserSurfaceAttachment(surface: right),
                         incomingID: BrowserSurfaceAttachment(surface: incoming)]
      let split = BrowserSplitLayout(leftTabID: leftID, rightTabID: rightID, fraction: 0.6)
      host.present(containers: attachments, selectedTabID: rightID, split: split)
      let originals = [left.nativeView.frame, right.nativeView.frame]
      left.clearRenderSizes(); right.clearRenderSizes()
      host.previewSplit(at: .init(side: .right))
      sampleLayout(host, duration: AnimationValues.SplitPages.layoutDuration * 2) {
        XCTAssertEqual(left.nativeView.frame, originals[0])
        XCTAssertEqual(right.nativeView.frame, originals[1])
      }
      host.previewSplit(at: nil)
      sampleLayout(host, duration: AnimationValues.SplitPages.layoutDuration * 2) {
        XCTAssertEqual(left.nativeView.frame, originals[0])
        XCTAssertEqual(right.nativeView.frame, originals[1])
      }
      XCTAssertTrue(left.renderSizes.isEmpty)
      XCTAssertTrue(right.renderSizes.isEmpty)
      host.previewSplit(at: .init(side: .right))
      let committed = split.placingPane(incomingID, at: .init(side: .right))
      XCTAssertTrue(host.commitSplitDrop {
        host.present(containers: attachments, selectedTabID: incomingID, split: committed)
        return true
      })
      let frames = committed.paneFrames(in: host.bounds).panes
      XCTAssertEqual(left.nativeView.frame.size, frames[0].size)
      XCTAssertEqual(right.nativeView.frame.size, frames[1].size)
      XCTAssertEqual(left.renderSizes, [frames[0].size])
      XCTAssertEqual(right.renderSizes, [frames[1].size])
    }
  }

  @MainActor
  private func sampleLayout(_ host: BrowserSurfaceHostView, duration: TimeInterval, check: () -> Void) {
    let end = Date().addingTimeInterval(duration)
    repeat {
      host.layout()
      CATransaction.flush()
      check()
      RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
    } while Date() < end
  }

  @MainActor
  private func withHost(_ check: (BrowserSurfaceHostView) throws -> Void) throws {
    try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  "Reduce Motion disables deferred animated drops")
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 700),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = BrowserSurfaceHostView(frame: window.contentView!.bounds)
    host.containerFeedback = { _ in }
    window.contentView = host
    // Exercise the real host and animation handoff without showing a window
    // or creating any browser runtimes.
    try check(host)
  }

  @MainActor
  func testSinglePageCentreReplacementRevealsTheDeferredPage() throws {
    try withHost { host in
      let outgoingID = UUID(), incomingID = UUID()
      let outgoing = DropTestSurface(), incoming = DropTestSurface()
      let attachments = [outgoingID: BrowserSurfaceAttachment(surface: outgoing),
                         incomingID: BrowserSurfaceAttachment(surface: incoming)]
      host.present(containers: attachments, selectedTabID: outgoingID)
      // Match the reported drag: edge compression, then centre replacement.
      host.previewSplit(at: .init(side: .left))
      host.previewSplit(at: .init(side: .middle))
      XCTAssertTrue(host.commitSplitDrop {
        host.present(containers: attachments, selectedTabID: incomingID)
        return true
      })
      XCTAssertTrue(try XCTUnwrap(incoming.nativeView.superview).isHidden)
      let landing = try XCTUnwrap(host.splitLandingFrame(for: [incomingID]))
      XCTAssertEqual(landing, host.convert(host.bounds, to: nil))
      XCTAssertNil(host.splitLandingFrame(for: [outgoingID]))
      host.revealSplitPages(for: [incomingID], from: card(in: landing), onCompletion: {})
      XCTAssertFalse(try XCTUnwrap(incoming.nativeView.superview).isHidden)
      XCTAssertEqual(incoming.nativeView.frame.size, host.bounds.size)
      XCTAssertTrue(incoming.visible)
      // Subsequent preview cleanup/layout must not hide the incoming page.
      host.previewPaneDrag(nil)
      host.previewSplit(at: nil)
      host.layout()
      XCTAssertFalse(try XCTUnwrap(incoming.nativeView.superview).isHidden)
    }
  }

  @MainActor
  func testSinglePageReplacementWithoutCardGeometryStillRestoresVisibility() throws {
    try withHost { host in
      let outgoingID = UUID(), incomingID = UUID()
      let incoming = DropTestSurface()
      let attachments = [outgoingID: BrowserSurfaceAttachment(surface: DropTestSurface()),
                         incomingID: BrowserSurfaceAttachment(surface: incoming)]
      host.present(containers: attachments, selectedTabID: outgoingID)
      host.previewSplit(at: .init(side: .middle))
      XCTAssertTrue(host.commitSplitDrop {
        host.present(containers: attachments, selectedTabID: incomingID)
        return true
      })
      var completed = false
      host.revealSplitPages(for: [incomingID], from: .zero) { completed = true }
      XCTAssertTrue(completed)
      XCTAssertFalse(try XCTUnwrap(incoming.nativeView.superview).isHidden)
      XCTAssertEqual(incoming.nativeView.frame.size, host.bounds.size)
    }
  }

  @MainActor
  func testSplitPaneReplacementKeepsItsPaneLandingAndReveals() throws {
    try withHost { host in
      let leftID = UUID(), rightID = UUID(), incomingID = UUID()
      let incoming = DropTestSurface()
      let attachments = [leftID: BrowserSurfaceAttachment(surface: DropTestSurface()),
                         rightID: BrowserSurfaceAttachment(surface: DropTestSurface()),
                         incomingID: BrowserSurfaceAttachment(surface: incoming)]
      let original = BrowserSplitLayout(leftTabID: leftID, rightTabID: rightID, fraction: 0.65)
      host.present(containers: attachments, selectedTabID: leftID, split: original)
      let target = BrowserSplitLayout.DropTarget(side: .right, replacesPane: true)
      host.previewSplit(at: target)
      let replacement = original.placingPane(incomingID, at: target)
      XCTAssertTrue(host.commitSplitDrop {
        host.present(containers: attachments, selectedTabID: incomingID, split: replacement)
        return true
      })
      let landing = try XCTUnwrap(host.splitLandingFrame(for: [incomingID]))
      let pane = replacement.paneFrames(in: host.bounds).panes[1]
      XCTAssertEqual(landing, host.convert(pane, to: nil))
      host.revealSplitPages(for: [incomingID], from: card(in: landing), onCompletion: {})
      XCTAssertFalse(try XCTUnwrap(incoming.nativeView.superview).isHidden)
      XCTAssertEqual(incoming.nativeView.frame.size, pane.size)
    }
  }

  private func card(in landing: CGRect) -> CGRect {
    CGRect(x: landing.midX - 72, y: landing.midY - 100, width: 144, height: 200)
  }
}

@MainActor
private final class DropTestSurface: BrowserNativeSurface {
  private let view = DropTestView(frame: .zero)
  var nativeView: NSView { view }
  var renderSizes: [CGSize] { view.renderSizes }
  func clearRenderSizes() { view.renderSizes.removeAll() }
  var browserSession: (any BrowserSessionProtocol)? { nil }
  private(set) var visible = false
  func setSurfaceVisible(_ visible: Bool) { self.visible = visible }
}

@MainActor
private final class DropTestView: NSView {
  var renderSizes: [CGSize] = []
  override var frame: NSRect {
    didSet { if oldValue.size != frame.size { renderSizes.append(frame.size) } }
  }
}
