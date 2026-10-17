@testable import CioUI
import SwiftUI
import XCTest
import AppKit
import Combine

final class SpaceOverviewMotionTests: XCTestCase {
  @MainActor
  func testScrubbingDoesNotResizeSplitViewOrInvalidateSwiftUIEveryFrame() {
    let split = CountingSplitView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    split.isVertical = true
    split.addArrangedSubview(NSView())
    split.addArrangedSubview(NSView())
    let motion = SpaceOverviewLayoutMotion()
    var viewUpdates = 0
    var nativeFrames = 0
    let state = motion.objectWillChange.sink { viewUpdates += 1 }
    let frames = motion.frames.sink { _ in nativeFrames += 1 }
    for index in 0..<240 {
      motion.preview(split, progress: CGFloat(index) / 239, normalWidth: 182, overviewWidth: 720)
    }
    XCTAssertEqual(split.dividerUpdates, 0, "Input must not enter constraint-based divider layout")
    XCTAssertEqual(viewUpdates, 1, "Only the interaction boundary invalidates the view graph")
    XCTAssertEqual(nativeFrames, 240)
    motion.preview(split, progress: 1, normalWidth: 182, overviewWidth: 720)
    XCTAssertEqual(nativeFrames, 240, "An identical pose must not repeat native work")
    withExtendedLifetime([state, frames]) {}
  }

  @MainActor
  func testRetainedSidebarHostsOnlyTranslateDuringScrubbing() {
    let surfaces = SpaceOverviewLayers<EmptyView, EmptyView>.SurfaceView(
      frame: CGRect(x: 0, y: 0, width: 720, height: 900))
    surfaces.isTransitioning = true
    let normalFrame = CGRect(x: 0, y: 0, width: 182, height: 900)
    let managerFrame = CGRect(x: 0, y: 0, width: 720, height: 900)
    for progress: CGFloat in [0, 0.2, 0.6, 1, 0.7, 0.3, 0] {
      let pose = SpaceOverviewPresentation(progress: progress, normalWidth: 182, overviewWidth: 720)
      surfaces.present(pose)
      XCTAssertEqual(surfaces.normal.frame, normalFrame)
      XCTAssertEqual(surfaces.normal.superview!.frame.minX, pose.normalOffset + 720 - pose.sidebarWidth, accuracy: 0.000001)
      XCTAssertEqual(surfaces.manager.frame, managerFrame)
      XCTAssertEqual(surfaces.manager.superview!.frame.minX, pose.overviewOffset + 720 - pose.sidebarWidth, accuracy: 0.000001)
    }
  }

  @MainActor
  private final class CountingSplitView: NSSplitView {
    var dividerUpdates = 0
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
      dividerUpdates += 1
      super.setPosition(position, ofDividerAt: dividerIndex)
    }
  }

  func testGestureCanScrubPastNormalSidebarWidthAllTheWayToEitherEnd() {
    var gesture = SpaceOverviewGesture(progress: 0, originalDestination: false)
    for _ in 0..<6 { gesture.scroll(120, travel: 720) }
    XCTAssertEqual(gesture.progress, 1, accuracy: 0.000001)
    XCTAssertTrue(gesture.destination)
    for _ in 0..<6 { gesture.scroll(-120, travel: 720) }
    XCTAssertEqual(gesture.progress, 0, accuracy: 0.000001)
    XCTAssertFalse(gesture.destination)
  }

  func testCrossingThresholdDoesNotLatchDestinationInEitherDirection() {
    var entering = SpaceOverviewGesture(progress: 0, originalDestination: false)
    entering.scroll(400, travel: 720)
    XCTAssertTrue(entering.destination)
    entering.scroll(-100, travel: 720)
    XCTAssertFalse(entering.destination)
    XCTAssertFalse(entering.originalDestination)

    var leaving = SpaceOverviewGesture(progress: 1, originalDestination: true)
    leaving.scroll(-400, travel: 720)
    XCTAssertFalse(leaving.destination)
    leaving.scroll(100, travel: 720)
    XCTAssertTrue(leaving.destination)
    XCTAssertTrue(leaving.originalDestination)
  }

  func testOverscrollReversesImmediatelyWithoutAccumulatedInputDebt() {
    var gesture = SpaceOverviewGesture(progress: 0, originalDestination: false)
    gesture.scroll(2000, travel: 720)
    gesture.scroll(-72, travel: 720)
    XCTAssertEqual(gesture.progress, 0.9, accuracy: 0.000001)
    gesture.scroll(-2000, travel: 720)
    gesture.scroll(72, travel: 720)
    XCTAssertEqual(gesture.progress, 0.1, accuracy: 0.000001)
  }

  func testInterruptedFlightStartsAtItsCurrentPresentation() {
    var gesture = SpaceOverviewGesture(progress: 0.65, originalDestination: true)
    gesture.scroll(-144, travel: 720)
    XCTAssertEqual(gesture.progress, 0.45, accuracy: 0.000001)
    XCTAssertFalse(gesture.destination)
    gesture.scroll(0, travel: 0)
    XCTAssertEqual(gesture.progress, 0.45, accuracy: 0.000001)
  }

  @MainActor
  func testBrowserRetainsRenderSizeAcrossEveryCropAndReversal() {
    let content = NSView()
    let viewport = SpaceOverviewBrowserViewport(content: content)
    viewport.frame = CGRect(x: 240, y: 0, width: 1200, height: 800)
    viewport.layoutSubtreeIfNeeded()
    viewport.retainedWidth = content.frame.width
    for sidebarWidth: CGFloat in [300, 450, 720, 550, 240, 720, 240] {
      viewport.frame = CGRect(x: sidebarWidth, y: 0, width: 1440 - sidebarWidth, height: 800)
      viewport.needsLayout = true
      viewport.layoutSubtreeIfNeeded()
      XCTAssertEqual(content.frame.size, CGSize(width: 1200, height: 800))
      XCTAssertEqual(content.frame.origin, .zero)
    }
    viewport.retainedWidth = nil
    XCTAssertEqual(content.frame.size, CGSize(width: 1200, height: 800))
    viewport.frame.size.width = 1300
    viewport.needsLayout = true
    viewport.layoutSubtreeIfNeeded()
    XCTAssertEqual(content.frame.width, 1300)
  }

  func testSurfacesStayEdgeToEdgeWhileDividerInterpolatesWithoutResizingNormalContent() {
    for overviewWidth: CGFloat in [180, 720] {
      let dividerWidths: [CGFloat] = overviewWidth == 180
        ? [240, 225, 210, 195, 180]
        : [240, 360, 480, 600, 720]
      for (index, progress) in [CGFloat(0), 0.25, 0.5, 0.75, 1].enumerated() {
        let presentation = SpaceOverviewPresentation(progress: progress,
          normalWidth: 240, overviewWidth: overviewWidth)

        XCTAssertEqual(presentation.normalOffset,
          presentation.overviewOffset + presentation.overviewWidth, accuracy: 0.000001)
        XCTAssertEqual(presentation.sidebarWidth, dividerWidths[index], accuracy: 0.000001)
        XCTAssertEqual(presentation.normalWidth, 240)
        XCTAssertEqual(presentation.overviewWidth, overviewWidth)
      }
    }
  }

  func testPresentationEndpointsKeepEachSurfaceAtItsOwnWidth() {
    let normal = SpaceOverviewPresentation(progress: 0, normalWidth: 240, overviewWidth: 720)
    XCTAssertEqual(normal.sidebarWidth, 240)
    XCTAssertEqual(normal.normalOffset, 0)
    XCTAssertEqual(normal.overviewOffset, -720)
    XCTAssertEqual(normal.normalWidth, 240)
    XCTAssertEqual(normal.overviewWidth, 720)

    let overview = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 720)
    XCTAssertEqual(overview.sidebarWidth, 720)
    XCTAssertEqual(overview.normalOffset, 720)
    XCTAssertEqual(overview.overviewOffset, 0)
    XCTAssertEqual(overview.normalWidth, 240)
    XCTAssertEqual(overview.overviewWidth, 720)
  }

  @MainActor
  func testZeroVelocityProgressIsMonotonicInBothDirections() {
    let normal = SpaceOverviewPresentation(progress: 0, normalWidth: 240, overviewWidth: 720)
    let overview = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 720)

    for (source, target) in [(normal, overview), (overview, normal)] {
      let flight = makeFlight(source: source, target: target)
      XCTAssertEqual(flight.presentation(at: flight.start), source)
      var previous = source.progress
      for index in 1...120 {
        let time = flight.start + flight.duration * Double(index) / 120
        let value = flight.presentation(at: time)
        XCTAssertGreaterThanOrEqual(value.progress, 0)
        XCTAssertLessThanOrEqual(value.progress, 1)
        if target.progress > source.progress {
          XCTAssertGreaterThanOrEqual(value.progress, previous)
        } else {
          XCTAssertLessThanOrEqual(value.progress, previous)
        }
        XCTAssertEqual(value.normalWidth, source.normalWidth)
        XCTAssertEqual(value.overviewWidth, 720, accuracy: 0.000001)
        XCTAssertEqual(value.normalOffset, value.overviewOffset + value.overviewWidth,
          accuracy: 0.000001)
        previous = value.progress
      }
      let midway = flight.presentation(at: flight.start + 0.1)
      XCTAssertGreaterThan(midway.progress, 0)
      XCTAssertLessThan(midway.progress, 1)
      XCTAssertEqual(previous, target.progress)
    }
  }

  @MainActor
  func testFlightReachesExactTargetAndStopsAtCapturedDuration() {
    let source = SpaceOverviewPresentation(progress: 0, normalWidth: 240, overviewWidth: 480)
    let target = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 840)
    // End before the spring naturally settles to exercise the captured deadline.
    let flight = makeFlight(source: source, target: target, duration: 0.125)
    let beforeEnd = flight.presentation(at: flight.start + flight.duration / 2)
    XCTAssertGreaterThan(beforeEnd.progress, 0)
    XCTAssertLessThan(beforeEnd.progress, 1)
    XCTAssertGreaterThan(beforeEnd.overviewWidth, source.overviewWidth)
    XCTAssertLessThan(beforeEnd.overviewWidth, target.overviewWidth)

    for time in [flight.start + flight.duration, flight.start + flight.duration + 1] {
      XCTAssertEqual(flight.presentation(at: time), target)
      XCTAssertEqual(flight.velocity(at: time).progress, 0)
      XCTAssertEqual(flight.velocity(at: time).width, 0)
    }
  }

  @MainActor
  func testReversalPreservesSampledPresentationAndBothVelocities() {
    let source = SpaceOverviewPresentation(progress: 0, normalWidth: 240, overviewWidth: 480)
    let target = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 840)
    let outgoing = makeFlight(source: source, target: target)
    let interruption = outgoing.start + 0.08
    let sampled = outgoing.presentation(at: interruption)
    let velocity = outgoing.velocity(at: interruption)
    XCTAssertGreaterThan(sampled.progress, 0)
    XCTAssertLessThan(sampled.progress, 1)
    XCTAssertGreaterThan(velocity.progress, 0)
    XCTAssertGreaterThan(velocity.width, 0)

    let reversed = SpaceOverviewLayoutMotion.Flight(start: interruption, source: sampled,
      target: source, velocity: velocity, spring: outgoing.spring, duration: outgoing.duration)
    assertSamePresentation(reversed.presentation(at: interruption), sampled)
    XCTAssertEqual(reversed.velocity(at: interruption).progress, velocity.progress, accuracy: 0.000001)
    XCTAssertEqual(reversed.velocity(at: interruption).width, velocity.width, accuracy: 0.000001)

    // The next sample still travels with the inherited momentum before turning.
    let step = 0.000001
    let continued = reversed.presentation(at: interruption + step)
    XCTAssertEqual(Double(continued.progress - sampled.progress) / step,
      velocity.progress, accuracy: 0.001)
    XCTAssertEqual(Double(continued.overviewWidth - sampled.overviewWidth) / step,
      velocity.width, accuracy: 1)
    XCTAssertEqual(reversed.presentation(at: interruption + reversed.duration), source)
  }

  @MainActor
  func testCapturedSpringAndDurationUseElapsedTimeRatherThanAbsoluteStart() {
    let source = SpaceOverviewPresentation(progress: 0, normalWidth: 240, overviewWidth: 480)
    let target = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 840)
    let original = makeFlight(source: source, target: target, duration: 0.125)
    let shifted = SpaceOverviewLayoutMotion.Flight(start: original.start + 100,
      source: source, target: target, velocity: original.velocity,
      spring: original.spring, duration: original.duration)

    for elapsed in [0, 0.03125, 0.0625, original.duration, original.duration + 1] {
      assertSamePresentation(shifted.presentation(at: shifted.start + elapsed),
        original.presentation(at: original.start + elapsed))
      XCTAssertEqual(shifted.velocity(at: shifted.start + elapsed).progress,
        original.velocity(at: original.start + elapsed).progress, accuracy: 0.000001)
      XCTAssertEqual(shifted.velocity(at: shifted.start + elapsed).width,
        original.velocity(at: original.start + elapsed).width, accuracy: 0.000001)
    }
  }

  @MainActor
  func testWidthOnlyRetargetKeepsOverviewOpenAndWidthContinuous() {
    let source = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 480)
    let target = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 840)
    let outgoing = makeFlight(source: source, target: target)
    let interruption = outgoing.start + 0.08
    let sampled = outgoing.presentation(at: interruption)
    let velocity = outgoing.velocity(at: interruption)
    XCTAssertGreaterThan(sampled.overviewWidth, source.overviewWidth)
    XCTAssertLessThan(sampled.overviewWidth, target.overviewWidth)
    XCTAssertGreaterThan(velocity.width, 0)

    let narrower = SpaceOverviewPresentation(progress: 1, normalWidth: 240, overviewWidth: 360)
    let retargeted = SpaceOverviewLayoutMotion.Flight(start: interruption, source: sampled,
      target: narrower, velocity: velocity, spring: outgoing.spring, duration: outgoing.duration)
    assertSamePresentation(retargeted.presentation(at: interruption), sampled)
    XCTAssertEqual(retargeted.velocity(at: interruption).width, velocity.width, accuracy: 0.000001)
    let step = 0.000001
    XCTAssertEqual(Double(retargeted.presentation(at: interruption + step).overviewWidth
      - sampled.overviewWidth) / step, velocity.width, accuracy: 1)

    for flight in [outgoing, retargeted] {
      for index in 0...120 {
        let value = flight.presentation(at: flight.start + flight.duration * Double(index) / 120)
        XCTAssertEqual(value.progress, 1)
        XCTAssertEqual(value.normalWidth, 240)
        XCTAssertEqual(value.sidebarWidth, value.overviewWidth, accuracy: 0.000001)
        XCTAssertEqual(value.overviewOffset, 0)
        XCTAssertEqual(value.normalOffset, value.overviewWidth, accuracy: 0.000001)
      }
    }
    XCTAssertEqual(retargeted.presentation(at: interruption + retargeted.duration), narrower)
  }

  @MainActor
  private func makeFlight(source: SpaceOverviewPresentation, target: SpaceOverviewPresentation,
                          duration: TimeInterval = 1.5) -> SpaceOverviewLayoutMotion.Flight {
    SpaceOverviewLayoutMotion.Flight(start: 10, source: source, target: target,
      velocity: .init(), spring: Spring(duration: 0.44, bounce: 0), duration: duration)
  }

  private func assertSamePresentation(_ actual: SpaceOverviewPresentation,
                                      _ expected: SpaceOverviewPresentation,
                                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.progress, expected.progress, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.normalWidth, expected.normalWidth, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.overviewWidth, expected.overviewWidth, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.sidebarWidth, expected.sidebarWidth, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.normalOffset, expected.normalOffset, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.overviewOffset, expected.overviewOffset, accuracy: 0.000001, file: file, line: line)
  }
}
