import AppKit
import CioUI
import Foundation

/// Native render-envelope regression, linked against the same CioUI object as
/// the app. It catches the rectangular window shadow and clipped dispersion;
/// it does not claim to measure WindowServer's high-refresh optical output.
@main
struct RecentTabFrameProbe {
  @MainActor static func main() {
    _ = NSApplication.shared
    let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    let chooser = RecentTabSwitcherPanel { _ in }
    defer { chooser.window.close(); parent.close() }
    let ids = (0..<5).map { _ in UUID() }
    chooser.update(candidates: ids.map {
      RecentTabCandidate(id: $0, title: "Preview", host: "example.com", favicon: nil, preview: nil)
    }, selectedID: ids[1])
    chooser.layout(in: parent)
    print("render envelope: \(chooser.window.frame); parent: \(parent.frame)")
    var failures = 0
    func check(_ passed: Bool, _ label: String) {
      print("\(passed ? "PASS" : "FAIL"): \(label)")
      if !passed { failures += 1 }
    }
    check(!chooser.window.hasShadow, "no rectangular NSPanel shadow outside the native glass outline")
    // The footer-free content uses the production card geometry. Shared 1.12
    // dispersion and 5 pt blur must fit without hitting a window crop edge.
    let content = RecentTabSwitcherLayout(count: 5, availableWidth: 1200).size
    check(chooser.window.frame.width >= content.width * 1.12 + 10,
          "horizontal dispersion has transparent compositor clearance")
    check(chooser.window.frame.height >= content.height * 1.12 + 10,
          "vertical dispersion has transparent compositor clearance")
    check(abs(chooser.window.frame.midX - parent.frame.midX) <= 0.5
          && abs(chooser.window.frame.midY - parent.frame.midY) <= 0.5,
          "render clearance preserves the resting component center")
    exit(failures == 0 ? 0 : 1)
  }
}
