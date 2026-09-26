// TEMPORARY verification probe for the sidebar glass drag. Not for commit.
import AppKit

@MainActor
enum SidebarDragProbe {
  private static var timer: Timer?
  private static var started = false

  static func installIfRequested(runtime: ApplicationRuntime) {
    guard CommandLine.arguments.contains("--sidebar-drag-probe") || CommandLine.arguments.contains("--sidebar-drag-anim") else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      MainActor.assumeIsolated { tick(runtime: runtime) }
    }
  }

  private static func tick(runtime: ApplicationRuntime) {
    guard !started, runtime.didAppearInWindow, SidebarTabDrag.probeInstance != nil else { return }
    started = true
    timer?.invalidate()
    Task { @MainActor in
      if CommandLine.arguments.contains("--sidebar-drag-anim") { await animation(runtime: runtime) } else { await run(runtime: runtime) }
    }
  }

  private static func log(_ message: String) {
    print("PROBE \(message)")
    fflush(stdout)
  }

  private static var window: NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.title == "NativeBrowser" } ?? NSApp.windows.first { $0.isVisible }
  }

  private static func sidebarView() -> NSView? {
    func find(_ view: NSView) -> NSSplitView? {
      if let split = view as? NSSplitView, split.isVertical { return split }
      for sub in view.subviews { if let found = find(sub) { return found } }
      return nil
    }
    guard let root = window?.contentView, let split = find(root) else { return nil }
    return split.arrangedSubviews.first
  }

  private static func windowPoint(_ point: CGPoint) -> NSPoint? {
    guard let view = sidebarView() else { return nil }
    let local = NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
    return view.convert(local, to: nil)
  }

  private static func post(_ type: NSEvent.EventType, _ point: CGPoint) {
    guard let window, let location = windowPoint(point),
      let event = NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    else { log("cannot post \(type)"); return }
    NSApp.postEvent(event, atStart: false)
  }

  private static func postEscape() {
    guard let window,
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53)
    else { return }
    NSApp.postEvent(event, atStart: false)
  }

  private static func sleep(_ seconds: Double) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
  }

  /// Presses at `from`, moves to `to` in small steps, optionally holds, and releases.
  private static func drag(
    from: CGPoint, to: CGPoint, hold: String?, escapeMidway: Bool = false
  ) async {
    post(.leftMouseDown, from)
    await sleep(0.08)
    log("after mouse down: mode=\(RunLoop.main.currentMode?.rawValue ?? "nil")")
    let steps = 28
    for step in 1...steps {
      let t = CGFloat(step) / CGFloat(steps)
      let eased = t * t * (3 - 2 * t)
      post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased))
      await sleep(0.016)
      if escapeMidway, step == steps / 2 {
        await sleep(0.3)
        log("before escape: dragging=\(SidebarTabDrag.probeInstance?.isDragging ?? false) mode=\(RunLoop.main.currentMode?.rawValue ?? "nil")")
        postEscape()
        let peekTracking = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .eventTracking, dequeue: false)
        let peekDefault = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: false)
        log("probe peek tracking=\(peekTracking?.keyCode.description ?? "nil") default=\(peekDefault?.keyCode.description ?? "nil")")
        await sleep(0.3)
        log("after escape: dragging=\(SidebarTabDrag.probeInstance?.isDragging ?? false)")
      }
    }
    if let hold {
      await sleep(0.5)
      log("HOLD \(hold)")
      await sleep(4.5)
    }
    post(.leftMouseUp, to)
    await sleep(1.0)
  }

  private static func animation(runtime: ApplicationRuntime) async {
    let workspace = runtime.workspaceStore
    for (url, title) in [("https://www.apple.com/", "Apple"), ("https://github.com/", "GitHub"),
                         ("https://www.wikipedia.org/", "Wikipedia"), ("https://news.ycombinator.com/", "Hacker News")] {
      _ = workspace.createTab(url: URL(string: url), title: title)
    }
    await sleep(4)
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
    for _ in 0..<50 where !(NSApp.isActive && window?.isKeyWindow == true) { await sleep(0.1) }
    await sleep(1.0)
    guard let drag = SidebarTabDrag.probeInstance else { return }
    let ids = workspace.temporaryTabs.map(\.id)
    guard let source = drag.probeFrame(of: ids[1]), let target = drag.probeFrame(of: ids[3]) else { log("no frames"); return }
    let from = CGPoint(x: source.midX - 40, y: source.midY)
    let to = CGPoint(x: source.midX - 34, y: target.maxY - 6)
    log("SNAP before")
    await sleep(0.5)
    post(.leftMouseDown, from)
    await sleep(0.08)
    for step in 1...3 { post(.leftMouseDragged, CGPoint(x: from.x, y: from.y + CGFloat(step) * 2)); await sleep(0.016) }
    log("SNAP lift-0")
    await sleep(0.15)
    log("SNAP lift-1")
    await sleep(0.4)
    for step in 1...30 {
      let t = CGFloat(step) / 30
      post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + 6 + (to.y - from.y - 6) * t))
      await sleep(0.016)
      if step == 15 { log("SNAP moving") }
    }
    await sleep(0.6)
    log("SNAP hover")
    await sleep(0.6)
    post(.leftMouseUp, to)
    await sleep(0.02)
    log("SNAP land-0")
    await sleep(0.1)
    log("SNAP land-1")
    await sleep(0.1)
    log("SNAP land-2")
    await sleep(0.12)
    log("SNAP land-3")
    await sleep(0.3)
    log("SNAP after")
    await sleep(0.8)
    log("DONE")
    NSApp.terminate(nil)
  }

  private static func run(runtime: ApplicationRuntime) async {
    let workspace = runtime.workspaceStore
    let sites = [
      ("https://www.apple.com/", "Apple"),
      ("https://github.com/", "GitHub"),
      ("https://www.wikipedia.org/", "Wikipedia"),
      ("https://news.ycombinator.com/", "Hacker News"),
      ("https://developer.apple.com/", "Apple Developer"),
    ]
    for (url, title) in sites { _ = workspace.createTab(url: URL(string: url), title: title) }
    await sleep(3.5)
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
    for _ in 0..<50 where !(NSApp.isActive && window?.isKeyWindow == true) { await sleep(0.1) }
    await sleep(0.8)
    log("active=\(NSApp.isActive) key=\(window?.isKeyWindow == true)")

    guard let drag = SidebarTabDrag.probeInstance else { log("no drag model"); return }
    func temporary() -> [UUID] { workspace.temporaryTabs.map(\.id) }
    func names(_ ids: [UUID]) -> String { ids.map { workspace.tab(withID: $0)?.displayTitle ?? "?" }.joined(separator: " | ") }
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      if !ok { failures += 1 }
      log("\(ok ? "PASS" : "FAIL") \(name)")
    }

    // 10. The resize handle still resizes and does not start a tab drag.
    let widthBefore = drag.probeBounds.width
    let edge = CGPoint(x: widthBefore - 3, y: drag.probeBounds.midY)
    if let window, let location = windowPoint(edge) {
      let hit = window.contentView?.hitTest(window.contentView!.convert(location, from: nil))
      log("resize hit: \(hit.map { String(describing: type(of: $0)) } ?? "nil") at \(location)")
    }
    post(.leftMouseDown, edge)
    await sleep(0.08)
    for step in 1...10 {
      post(.leftMouseDragged, CGPoint(x: edge.x + CGFloat(step) * 4, y: edge.y))
      await sleep(0.02)
    }
    post(.leftMouseUp, CGPoint(x: edge.x + 40, y: edge.y))
    await sleep(0.6)
    log("resize: \(widthBefore) -> \(drag.probeBounds.width) dragging=\(drag.isDragging)")
    check("resize handle", drag.probeBounds.width > widthBefore + 20 && !drag.isDragging)

    // 1. Reorder within temporary: second tab goes between the fourth and fifth.
    var ids = temporary()
    log("temporary before: \(names(ids))")
    if ids.count >= 5, let source = drag.probeFrame(of: ids[1]), let fifth = drag.probeFrame(of: ids[4]) {
      let expected = [ids[0], ids[2], ids[3], ids[1]] + ids[4...]
      await self.drag(from: CGPoint(x: source.midX, y: source.midY),
                      to: CGPoint(x: source.midX + 10, y: fifth.minY - 1), hold: "reorder")
      log("temporary after: \(names(temporary()))")
      check("reorder", temporary() == Array(expected))
    } else { check("reorder frames", false) }

    // 2. Cancel by leaving the sidebar.
    ids = temporary()
    if let source = drag.probeFrame(of: ids[0]) {
      await self.drag(from: CGPoint(x: source.midX, y: source.midY),
                      to: CGPoint(x: drag.probeBounds.maxX + 80, y: source.midY + 60), hold: "outside")
      check("cancel outside", temporary() == ids)
    }

    // 4. Pin into the empty top pin area; the block becomes a tile.
    ids = temporary()
    if let source = drag.probeFrame(of: ids[2]) {
      let moving = ids[2]
      let top = drag.probeTopPinFrame
      await self.drag(from: CGPoint(x: source.midX, y: source.midY),
                      to: CGPoint(x: 50, y: top.maxY - 33), hold: "pin")
      check("pin globally", workspace.globalPinnedTabs.map(\.id) == [moving])
      // 5. Drag that tile back to the top of temporary.
      await sleep(0.5)
      if let tile = drag.probeFrame(of: moving), let first = drag.probeFrame(of: temporary()[0]) {
        await self.drag(from: CGPoint(x: tile.midX, y: tile.midY),
                        to: CGPoint(x: first.midX, y: first.minY + 4), hold: "unpin")
        check("tile back to temporary", temporary().first == moving && workspace.globalPinnedTabs.isEmpty)
      } else { check("tile frames", false) }
    } else { check("pin frames", false) }

    // 6. Drop on the Space title: becomes the first space pin.
    ids = temporary()
    if let source = drag.probeFrame(of: ids[3]), let pins = drag.probeTierFrame(.space(workspace.selectedSpaceID)) {
      let moving = ids[3]
      await self.drag(from: CGPoint(x: source.midX, y: source.midY),
                      to: CGPoint(x: source.midX, y: pins.midY), hold: "space-pin")
      check("space pin", workspace.spacePinnedTabs.map(\.id) == [moving])
    }

    // 7. A click still selects.
    ids = temporary()
    if let target = drag.probeFrame(of: ids[0]) {
      post(.leftMouseDown, CGPoint(x: target.midX - 30, y: target.midY))
      await sleep(0.06)
      post(.leftMouseUp, CGPoint(x: target.midX - 30, y: target.midY))
      await sleep(0.6)
      check("click selects", workspace.selectedTabID == ids[0])
    }

    // 8. A tiny drag neither moves nor selects.
    ids = temporary()
    let selected = workspace.selectedTabID
    if let target = drag.probeFrame(of: ids[2]) {
      await self.drag(from: CGPoint(x: target.midX, y: target.midY),
                      to: CGPoint(x: target.midX + 3, y: target.midY + 6), hold: nil)
      log("tiny drag: order same=\(temporary() == ids) selection same=\(workspace.selectedTabID == selected)")
      check("tiny drag", temporary() == ids && workspace.selectedTabID == selected)
    }

    // 9. Autoscroll: with a long list, dragging to the bottom edge scrolls it.
    for index in 1...18 {
      _ = workspace.createTab(
        url: URL(string: "data:text/html,%3Ctitle%3ETab%20\(index)%3C/title%3E"), select: false,
        title: "Tab \(index)")
    }
    await sleep(1.5)
    ids = temporary()
    if let source = drag.probeFrame(of: ids[0]) {
      let bottom = drag.probeBounds.maxY - 70
      post(.leftMouseDown, CGPoint(x: source.midX, y: source.midY))
      await sleep(0.08)
      for step in 1...20 {
        post(.leftMouseDragged, CGPoint(x: source.midX, y: source.midY + (bottom - source.midY) * CGFloat(step) / 20))
        await sleep(0.016)
      }
      await sleep(0.4)
      log("HOLD autoscroll")
      await sleep(2.2)
      post(.leftMouseUp, CGPoint(x: source.midX, y: bottom))
      await sleep(1.2)
      let index = temporary().firstIndex(of: ids[0]) ?? -1
      log("autoscroll landed at index \(index) of \(ids.count)")
      check("autoscroll", index >= 14)
    }

    // 11. The selected row's close button still closes it.
    if let selectedID = workspace.selectedTabID, let row = drag.probeFrame(of: selectedID) {
      let count = workspace.allTabIDs.count
      let point = CGPoint(x: row.maxX - 3 - 14.5, y: row.midY)
      post(.leftMouseDown, point)
      await sleep(0.06)
      post(.leftMouseUp, point)
      await sleep(0.8)
      check("close button", workspace.allTabIDs.count == count - 1 && workspace.tab(withID: selectedID) == nil)
    } else { check("close frames", false) }

    log("DONE failures=\(failures)")
    await sleep(0.5)
    NSApp.terminate(nil)
  }
}
