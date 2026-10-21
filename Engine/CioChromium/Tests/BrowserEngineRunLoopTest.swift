import Foundation

@_silgen_name("CioRunLoopTestStart") func engineStart()
@_silgen_name("CioRunLoopTestPump") func enginePump()
@_silgen_name("CioRunLoopTestCompleted") func completed() -> Int32
@_silgen_name("CioRunLoopTestPost") func post(_ delay: Int32, _ worker: Bool)
@_silgen_name("CioRunLoopTestStop") func engineStop()

@main
struct BrowserEngineRunLoopTest {
  @MainActor static func main() {
    engineStart()
    let driver = BrowserEngineRunLoopDriver()
    var passes = 0
    var depth = 0
    var maximumDepth = 0
    driver.start {
      depth += 1
      maximumDepth = max(maximumDepth, depth)
      passes += 1
      enginePump()
      depth -= 1
    }
    func spin(_ seconds: TimeInterval, mode: RunLoop.Mode = .default) {
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline { _ = RunLoop.main.run(mode: mode, before: deadline) }
    }
    spin(0.05)
    let before = passes
    spin(0.25)
    let idlePasses = passes - before
    FileHandle.standardOutput.write(Data("run-loop-test: idle host passes in 250ms = \(idlePasses)\n".utf8))
    guard idlePasses <= 2 else {
      fatalError("Idle Chromium must sleep instead of polling at display frequency")
    }
    post(0, false)
    post(35, false)
    post(0, true)
    spin(0.15)
    precondition(completed() == 3, "Immediate, delayed and cross-thread tasks must run")
    // AppKit's tracking mode is a common mode, as during native menu/drag input.
    let tracking = RunLoop.Mode("NSEventTrackingRunLoopMode")
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: tracking.rawValue as CFString))
    post(0, true)
    post(20, false)
    spin(0.1, mode: tracking)
    precondition(completed() == 5, "Tracking loops must keep delivering engine tasks")
    precondition(maximumDepth == 1, "Host pumping must not recurse")
    driver.stop()
    let stopped = passes
    post(0, false)
    spin(0.05)
    precondition(passes == stopped && completed() == 5, "Stop must detach the host driver")
    enginePump()
    precondition(completed() == 6)
    engineStop()
    print("PASS: idle sleep, immediate/delayed/worker tasks, tracking, non-reentrancy and stop")
  }
}
