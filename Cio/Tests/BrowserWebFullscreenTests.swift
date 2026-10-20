import AppKit
import CioEngine
import CioModel
@testable import CioUI
import XCTest

final class BrowserWebFullscreenTests: XCTestCase {
  @MainActor
  func testHTMLFullscreenFillsShellAndRetainsTheSameSurfaceAcrossUpdates() throws {
    let (root, host) = makeHost()
    let id = UUID(), surface = FullscreenTestSurface()
    let attachments = [id: BrowserSurfaceAttachment(surface: surface)]
    host.present(containers: attachments, selectedTabID: id)
    let viewport = try XCTUnwrap(surface.nativeView.superview)
    let restingFrame = viewport.frame

    for _ in 0..<2 {
      host.setWebFullscreen(true, for: id)
      XCTAssertTrue(root.shellContent.isHidden)
      XCTAssertTrue(viewport.superview === root)
      XCTAssertEqual(viewport.frame, root.bounds)
      XCTAssertEqual(surface.nativeView.frame, root.bounds)
      XCTAssertEqual(viewport.layer?.cornerRadius, 0)

      host.present(containers: attachments, selectedTabID: id)
      host.layout()
      XCTAssertEqual(surface.nativeView.frame, root.bounds, "Metadata/layout updates must not shrink the fullscreen player")
      XCTAssertTrue(surface.nativeView.superview === viewport)

      host.setWebFullscreen(false, for: id)
      XCTAssertFalse(root.shellContent.isHidden)
      XCTAssertTrue(viewport.superview === host)
      XCTAssertEqual(viewport.frame, restingFrame)
      XCTAssertEqual(surface.nativeView.frame, viewport.bounds)
    }
  }

  @MainActor
  func testFullscreenOfSplitPaneRestoresBothPanesAndTheirProportions() throws {
    let (root, host) = makeHost()
    let leftID = UUID(), rightID = UUID()
    let left = FullscreenTestSurface(), right = FullscreenTestSurface()
    let attachments = [leftID: BrowserSurfaceAttachment(surface: left), rightID: .init(surface: right)]
    let split = BrowserSplitLayout(leftTabID: leftID, rightTabID: rightID, fraction: 0.65)
    host.present(containers: attachments, selectedTabID: rightID, split: split)
    let leftViewport = try XCTUnwrap(left.nativeView.superview)
    let rightViewport = try XCTUnwrap(right.nativeView.superview)
    let leftFrame = leftViewport.frame, rightFrame = rightViewport.frame
    host.setWebFullscreen(true, for: rightID)
    XCTAssertEqual(right.nativeView.frame, root.bounds)
    host.present(containers: attachments, selectedTabID: rightID, split: split)
    XCTAssertEqual(right.nativeView.frame, root.bounds)
    host.setWebFullscreen(false, for: rightID)
    XCTAssertEqual(leftViewport.frame, leftFrame)
    XCTAssertEqual(rightViewport.frame, rightFrame)
    XCTAssertEqual(right.nativeView.frame, rightViewport.bounds)
    XCTAssertEqual(rightViewport.layer?.cornerRadius, BrowserLayout.contentCornerRadius)
    XCTAssertTrue(rightViewport.superview === host)
  }

  @MainActor
  func testResizeAndTabRemovalRestoreShellWithoutAFullscreenExitCallback() throws {
    let (root, host) = makeHost()
    let id = UUID(), surface = FullscreenTestSurface()
    host.present(containers: [id: .init(surface: surface)], selectedTabID: id)
    host.setWebFullscreen(true, for: id)
    root.setFrameSize(CGSize(width: 1600, height: 900))
    root.layoutSubtreeIfNeeded()
    XCTAssertEqual(surface.nativeView.frame.size, root.bounds.size)
    host.present(containers: [:], selectedTabID: nil)
    XCTAssertFalse(root.isPresenting)
    XCTAssertFalse(root.shellContent.isHidden)
  }

  @MainActor
  private func makeHost() -> (BrowserWebFullscreenHostView, BrowserSurfaceHostView) {
    let shell = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 700))
    let host = BrowserSurfaceHostView(frame: CGRect(x: 238, y: 56, width: 958, height: 640))
    shell.addSubview(host)
    let root = BrowserWebFullscreenHostView(shellContent: shell)
    host.webFullscreenHost = root
    return (root, host)
  }
}

@MainActor
private final class FullscreenTestSurface: BrowserNativeSurface {
  let nativeView = NSView()
  var browserSession: (any BrowserSessionProtocol)? { nil }
  func setSurfaceVisible(_ visible: Bool) { nativeView.isHidden = !visible }
}
