import Foundation

/// Keeps Chromium's task delegate attached during bounded passes of the host
/// run loop. The engine owns task scheduling; this class owns host integration.
@MainActor
final class BrowserEngineRunLoopDriver {
  private var observer: CFRunLoopObserver?
  private var work: (@MainActor () -> Void)?
  private var isDraining = false
  var isRunning: Bool { observer != nil }

  func start(work: @escaping @MainActor () -> Void) {
    guard observer == nil else { return }
    self.work = work
    // Chromium's CF sources and delayed-work timer already wake AppKit at the
    // correct deadline. Its delegate exists only inside RunUntilIdle, so drain
    // once before the host sleeps rather than polling on a display-rate timer.
    // Nested Chromium/menu loops retain their own pump and must not re-enter us.
    let observer = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.drain() }
    }
    self.observer = observer
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }

  func stop() {
    if let observer { CFRunLoopObserverInvalidate(observer) }
    observer = nil
    work = nil
  }

  private func drain() {
    guard !isDraining, let work else { return }
    isDraining = true
    defer { isDraining = false }
    work()
  }

  isolated deinit {
    if let observer { CFRunLoopObserverInvalidate(observer) }
  }
}
