@testable import CioUI
import AppKit
import SwiftUI
import XCTest

final class GlassComponentLayoutMotionTests: XCTestCase {
  @MainActor
  private func withHost(_ check: (NSView, NSView) throws -> Void) throws {
    try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  "Geometry flights are disabled by Reduce Motion")
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let parent = FlippedToolbarTestView(frame: window.contentView!.bounds)
    window.contentView = parent
    let host = NSHostingView(rootView: Color.clear.frame(width: 36, height: 36))
    host.safeAreaRegions = []
    host.wantsLayer = true
    host.frame = NSRect(x: 220, y: 10, width: 36, height: 36)
    parent.addSubview(host)
    parent.layoutSubtreeIfNeeded()
    CATransaction.flush()
    // Never order the window on screen. This deliberately exercises capture
    // before the compositor has published a presentation layer.
    try check(host, parent)
  }

  @MainActor
  func testCaptureBeforeRenderKeepsFlightOriginInsteadOfModelDestination() throws {
    try withHost { host, _ in
      let motion = GlassComponentLayoutMotion()
      let source = try XCTUnwrap(motion.capture(host))
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      host.frame.origin.x = 100
      motion.animate(host, from: source, enabled: true)
      let captured = try XCTUnwrap(motion.capture(host))
      XCTAssertEqual(captured.frameInWindow.midX, source.frameInWindow.midX, accuracy: 1)
      XCTAssertEqual(captured.frameInWindow.midY, source.frameInWindow.midY, accuracy: 1)
    }
  }

  @MainActor
  func testSecondDestinationInSameTransactionContinuesFromMovingOrigin() throws {
    try withHost { host, _ in
      let motion = GlassComponentLayoutMotion()
      let source = try XCTUnwrap(motion.capture(host))
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      host.frame.origin.x = 100
      motion.animate(host, from: source, enabled: true)
      let interrupted = try XCTUnwrap(motion.capture(host))
      host.frame.origin.x = 240
      motion.animate(host, from: interrupted, enabled: true)
      let retargeted = try XCTUnwrap(motion.capture(host))
      XCTAssertEqual(retargeted.frameInWindow.midX, interrupted.frameInWindow.midX, accuracy: 1)
      XCTAssertEqual(retargeted.frameInWindow.midY, interrupted.frameInWindow.midY, accuracy: 1)
      XCTAssertGreaterThan(abs(retargeted.frameInWindow.midX - host.frame.midX), 10)
    }
  }

  @MainActor
  func testLayoutCompletionAtSameDestinationDoesNotCancelFlight() throws {
    try withHost { host, _ in
      let motion = GlassComponentLayoutMotion()
      let source = try XCTUnwrap(motion.capture(host))
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      host.frame.origin.x = 100
      motion.animate(host, from: source, enabled: true)
      let interrupted = try XCTUnwrap(motion.capture(host))
      // Page completion can repeat layout with animation disabled. It must
      // preserve this component's independent, already-running flight.
      motion.animate(host, from: interrupted, enabled: false)
      let continued = try XCTUnwrap(motion.capture(host))
      XCTAssertEqual(continued.frameInWindow.midX, source.frameInWindow.midX, accuracy: 1)
      XCTAssertNotNil(host.layer?.animation(forKey: "glass-component-layout"))
    }
  }
}

private final class FlippedToolbarTestView: NSView {
  override var isFlipped: Bool { true }
}
