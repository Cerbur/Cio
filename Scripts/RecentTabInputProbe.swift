import AppKit
import CioModel
import CioUI

@main
struct RecentTabInputProbe {
  @MainActor static func main() async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    var commits = 0, reveals = 0, failures = 0
    let input = RecentTabSwitcherInputSession(onReveal: { reveals += 1 }, onCommit: { commits += 1 })
    func check(_ passed: Bool, _ label: String) {
      print("\(passed ? "PASS" : "FAIL"): \(label)")
      if !passed { failures += 1 }
    }
    // This is the captured failure: event flags contain Control while AppKit's
    // unrelated global snapshot is zero. No Control-release event has occurred.
    print("global Control snapshot: \(NSEvent.modifierFlags.contains(.control))")
    input.begin(controlDown: true)
    try? await Task.sleep(for: .milliseconds(90))
    check(commits == 0, "held Control must not commit without a release event")
    check(reveals == 1 && input.isVisible, "held gesture reveals once after its input threshold")
    let ids = (0..<5).map { _ in UUID() }
    var selection = RecentTabSelection(candidateIDs: ids, currentID: ids[0], forward: true)
    selection.advance(forward: true)
    selection.advance(forward: false)
    check(selection.selectedID == ids[1] && commits == 0, "left/right can change highlight while gesture remains open")
    input.controlChanged(isDown: false)
    input.controlChanged(isDown: false)
    check(commits == 1, "Control release commits once")
    input.end()

    commits = 0; reveals = 0
    input.begin(controlDown: true)
    input.controlChanged(isDown: false)
    try? await Task.sleep(for: .milliseconds(90))
    check(commits == 1, "quick release commits immediately and exactly once")
    check(reveals == 0, "quick release never reveals a late panel")
    input.end()

    commits = 0; reveals = 0
    input.begin(controlDown: true)
    input.end()
    try? await Task.sleep(for: .milliseconds(90))
    check(commits == 0 && reveals == 0, "cancel invalidates the old delayed callback")
    input.begin(controlDown: true)
    input.end()
    input.begin(controlDown: false)
    try? await Task.sleep(for: .milliseconds(90))
    check(reveals == 1 && commits == 0, "an old chord cannot affect a new menu session")
    input.controlChanged(isDown: false)
    check(commits == 0, "latched menu invocation ignores unrelated released modifiers")
    input.controlChanged(isDown: true)
    input.controlChanged(isDown: false)
    check(commits == 1, "a menu session can adopt a later held Control gesture")
    input.end()

    commits = 0; reveals = 0
    input.begin(controlDown: true)
    input.controlChanged(isDown: true)
    try? await Task.sleep(for: .milliseconds(90))
    check(reveals == 1 && commits == 0, "repeated Control state does not postpone or end the gesture")
    input.end()
    exit(failures == 0 ? 0 : 1)
  }
}
