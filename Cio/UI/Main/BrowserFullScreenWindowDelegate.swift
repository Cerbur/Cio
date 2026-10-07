import AppKit

/// Changes only the native full-screen chrome policy, forwarding the scene's
/// existing window callbacks so SwiftUI retains its window lifecycle behavior.
@MainActor
final class BrowserFullScreenWindowDelegate: NSObject, NSWindowDelegate {
  // NSObject's forwarding entry points are nonisolated. AppKit calls this
  // window delegate on the main thread, including selector discovery.
  nonisolated(unsafe) private weak var sceneDelegate: NSWindowDelegate?

  init(sceneDelegate: NSWindowDelegate?) {
    self.sceneDelegate = sceneDelegate
    super.init()
  }

  func restoreDelegate(in window: NSWindow) {
    if window.delegate === self {
      window.delegate = sceneDelegate
    }
  }

  func window(
    _ window: NSWindow,
    willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    var options = sceneDelegate?.window?(
      window, willUseFullScreenPresentationOptions: proposedOptions) ?? proposedOptions
    // The empty native toolbar exists only to contain the windowed traffic
    // lights. In full screen, let AppKit reveal it with the menu bar instead
    // of leaving a separate system row over the shell's command bar.
    options.formUnion([.fullScreen, .autoHideToolbar, .autoHideMenuBar])
    options.remove(.hideMenuBar)
    return options
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || sceneDelegate?.responds(to: aSelector) == true
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if let sceneDelegate, sceneDelegate.responds(to: aSelector) {
      return sceneDelegate
    }
    return super.forwardingTarget(for: aSelector)
  }
}
