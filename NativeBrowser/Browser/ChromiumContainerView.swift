//
//  ChromiumContainerView.swift
//  NativeBrowser
//
//  AppKit container that hosts the CEF browser view (ARCHITECTURE.md section 9).
//  It owns nothing but geometry: the Chromium browser view is added by CEF as a
//  child of this view, and BrowserSession reacts to the AppKit callbacks below.
//

import AppKit

@MainActor
protocol ChromiumContainerViewDelegate: AnyObject {
  /// The view was added to (or removed from) a window.
  func containerViewDidMoveToWindow(_ view: ChromiumContainerView)
  /// The view changed size; the browser must be told about it.
  func containerViewDidResize(_ view: ChromiumContainerView)
}

final class ChromiumContainerView: NSView {
  weak var delegate: ChromiumContainerViewDelegate?

  private let placeholderLabel: NSTextField = {
    let label = NSTextField(labelWithString: "Chromium browser view")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.alignment = .center
    label.textColor = .tertiaryLabelColor
    label.font = .systemFont(ofSize: 13)
    return label
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    addSubview(placeholderLabel)
    NSLayoutConstraint.activate([
      placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    ApplicationRuntime.shared.record("appkit:chromium-container-created")
    AppLog.browser.debug("ChromiumContainerView created")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Hides the placeholder once Chromium has attached its own view.
  func setBrowserAttached(_ attached: Bool) {
    placeholderLabel.isHidden = attached
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    delegate?.containerViewDidMoveToWindow(self)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    delegate?.containerViewDidResize(self)
  }

  deinit {
    AppLog.browser.debug("ChromiumContainerView released")
  }
}
