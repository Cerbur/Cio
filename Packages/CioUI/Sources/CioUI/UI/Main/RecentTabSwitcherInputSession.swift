import Foundation
import CioModel

/// Owns the held-key lifetime and delayed reveal independently of page focus.
/// Menu invocation stays latched; keyboard invocation commits on Control release.
/// Modifier-change events are authoritative: global modifier snapshots can lag
/// behind delivered keyboard events, particularly with remote/injected input.
@MainActor
public final class RecentTabSwitcherInputSession {
  private var activation = RecentTabSwitcherActivation()
  private var pendingReveal: DispatchWorkItem?
  private var requestedCommit = false
  public private(set) var waitsForControlRelease = false
  public var isVisible: Bool { activation.isVisible }
  private let onReveal: @MainActor () -> Void
  private let onCommit: @MainActor () -> Void

  public init(onReveal: @escaping @MainActor () -> Void, onCommit: @escaping @MainActor () -> Void) {
    self.onReveal = onReveal
    self.onCommit = onCommit
  }

  public func begin(controlDown: Bool) {
    end()
    waitsForControlRelease = controlDown
    let token = activation.begin(at: ProcessInfo.processInfo.systemUptime, waitsForControl: controlDown)
    if activation.isVisible { onReveal() }
    else {
      let reveal = DispatchWorkItem { [weak self] in
        guard let self, self.activation.token == token, !self.requestedCommit else { return }
        guard self.activation.reveal(token: token, at: ProcessInfo.processInfo.systemUptime) else { return }
        self.pendingReveal = nil
        self.onReveal()
      }
      pendingReveal = reveal
      DispatchQueue.main.asyncAfter(deadline: .now() + RecentTabSwitcherActivation.holdThreshold, execute: reveal)
    }
  }

  public func controlChanged(isDown: Bool) {
    guard activation.token != nil else { return }
    if isDown { waitsForControlRelease = true }
    else if waitsForControlRelease { requestCommit() }
  }

  public func end() {
    pendingReveal?.cancel()
    pendingReveal = nil
    activation.end()
    waitsForControlRelease = false
    requestedCommit = false
  }

  private func requestCommit() {
    guard activation.token != nil, !requestedCommit else { return }
    requestedCommit = true
    pendingReveal?.cancel()
    pendingReveal = nil
    onCommit()
  }
}
