import AppKit
import CioModel

@main
struct RecentTabSystemArrowProbe {
  @MainActor static func main() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    var eligible = true, advances = 0, failures = 0
    let ids = (0..<5).map { _ in UUID() }
    var selection = RecentTabSelection(candidateIDs: ids, currentID: ids[0], forward: true)
    let arrows = RecentTabSwitcherArrowKeys(isEligible: { eligible }, onAdvance: {
      selection.advance(forward: $0)
      advances += 1
    })
    func check(_ passed: Bool, _ label: String) {
      print("\(passed ? "PASS" : "FAIL"): \(label)")
      if !passed { failures += 1 }
    }
    func send(_ key: CGKeyCode, _ flags: CGEventFlags = .maskControl,
              type: CGEventType = .keyDown) -> Bool {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown)!
      event.type = type
      event.flags = flags
      return arrows.handle(type: type, event: event) == nil
    }

    check(!send(124) && advances == 0, "outside a switcher all keys pass through")
    arrows.begin()
    check(send(124) && selection.selectedID == ids[2] && advances == 1,
          "held Control-Right advances highlight and consumes the system shortcut")
    check(send(124, [], type: .keyUp) && advances == 1, "consume matching keyUp without a second advance")
    check(send(123) && selection.selectedID == ids[1] && advances == 2,
          "held Control-Left reverses highlight")
    for flags: CGEventFlags in [.maskControl, [.maskControl, .maskShift],
      [.maskControl, .maskSecondaryFn, .maskNumericPad], [.maskControl, .maskShift, .maskSecondaryFn]] {
      let before = advances
      check(send(124, flags) && advances == before + 1, "accept Control-arrow modifier variant \(flags.rawValue)")
    }
    let before = advances
    check(!send(124, []) && advances == before, "plain arrows retain ordinary routing")
    check(!send(124, [.maskControl, .maskCommand]) && advances == before, "Command chords pass through")
    check(!send(123, [.maskControl, .maskAlternate]) && advances == before, "Option chords pass through")
    check(!send(125) && advances == before, "unrelated keys pass through")
    eligible = false
    check(!send(124) && advances == before, "inactive or non-owning windows cannot consume arrows")
    eligible = true
    arrows.end()
    check(!send(123, [], type: .keyUp), "cleanup clears consumed key state")
    check(!send(124) && advances == before, "ending a flight removes arrow routing")
    arrows.begin()
    check(!send(123, [], type: .keyUp), "an old key release cannot affect a new flight")
    arrows.end()
    arrows.end()
    check(!send(124), "cleanup is idempotent")
    exit(failures == 0 ? 0 : 1)
  }
}
