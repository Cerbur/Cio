import AppKit
import ApplicationServices

/// Spaces can consume Control-arrows before AppKit or Carbon hotkeys see them.
/// A filtering tap owns only those arrows, only while this chooser is active.
/// It is installed only with an existing Accessibility grant; it never prompts.
@MainActor
final class RecentTabSwitcherArrowKeys {
  private let isEligible: () -> Bool
  private let onAdvance: (Bool) -> Void
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var isOpen = false
  private var consumedKeys = Set<CGKeyCode>()

  init(isEligible: @escaping () -> Bool, onAdvance: @escaping (Bool) -> Void) {
    self.isEligible = isEligible
    self.onAdvance = onAdvance
  }

  isolated deinit { end() }

  func begin() {
    end()
    isOpen = true
    // Creating a tap must not initiate a privacy prompt from Control-Tab.
    guard AXIsProcessTrusted() else { return }
    let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
      | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let consumed = MainActor.assumeIsolated {
          Unmanaged<RecentTabSwitcherArrowKeys>.fromOpaque(context).takeUnretainedValue()
            .handle(type: type, event: event) == nil
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return
    }
    self.tap = tap
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func end() {
    isOpen = false
    consumedKeys.removeAll()
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
    source = nil
    tap = nil
  }

  // Internal so the native probe can replay this exact filtering callback
  // without installing a tap or posting keyboard input to the user's desktop.
  func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if isOpen, isEligible(), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard isOpen, isEligible() else { return Unmanaged.passUnretained(event) }
    let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    if type == .keyUp {
      return consumedKeys.remove(key) != nil ? nil : Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, key == 123 || key == 124,
          event.flags.contains(.maskControl),
          event.flags.intersection([.maskCommand, .maskAlternate]).isEmpty else {
      return Unmanaged.passUnretained(event)
    }
    consumedKeys.insert(key)
    onAdvance(key == 124)
    return nil
  }
}
