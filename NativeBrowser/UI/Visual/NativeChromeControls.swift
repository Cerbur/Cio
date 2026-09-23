//
//  NativeChromeControls.swift
//  NativeBrowser
//
//  Small AppKit bridges for the icon-only controls in browser chrome.
//

import AppKit
import SwiftUI

struct NativeChromeSegment: Equatable {
  let systemImage: String
  let accessibilityLabel: String
  let isEnabled: Bool
}

/// One native AppKit segmented control for a related group of chrome actions.
/// SwiftUI owns the state and actions; this representable only renders and
/// forwards the selected segment index.
struct NativeGlassSegmentedControl: NSViewRepresentable {
  let segments: [NativeChromeSegment]
  let height: CGFloat
  let action: (Int) -> Void

  init(
    segments: [NativeChromeSegment],
    height: CGFloat = BrowserChromeLayout.chromeControlHeight,
    action: @escaping (Int) -> Void
  ) {
    self.segments = segments
    self.height = height
    self.action = action
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  func makeNSView(context: Context) -> NSGlassEffectView {
    let glassView = NSGlassEffectView(frame: .zero)
    glassView.style = .regular
    glassView.cornerRadius = height / 2
    if #available(macOS 27.0, *) {
      glassView.effectIsInteractive = true
    }

    let control = NSSegmentedControl(frame: .zero)
    control.segmentCount = segments.count
    control.trackingMode = .momentary
    control.segmentStyle = .automatic
    control.cell?.isBordered = true
    control.target = context.coordinator
    control.action = #selector(Coordinator.activateSegment(_:))
    control.autoresizingMask = [.width, .height]
    control.setContentCompressionResistancePriority(.required, for: .vertical)
    configure(control, coordinator: context.coordinator)
    glassView.contentView = control
    return glassView
  }

  func updateNSView(_ glassView: NSGlassEffectView, context: Context) {
    context.coordinator.action = action
    glassView.cornerRadius = height / 2
    guard let control = glassView.contentView as? NSSegmentedControl else { return }
    configure(control, coordinator: context.coordinator)
  }

  private func configure(_ control: NSSegmentedControl, coordinator: Coordinator) {
    if control.segmentCount != segments.count {
      control.segmentCount = segments.count
    }
    if coordinator.lastImages.count != segments.count {
      coordinator.lastImages = Array(repeating: nil, count: segments.count)
    }

    for (index, segment) in segments.enumerated() {
      let imageKey = "\(segment.systemImage)|\(segment.accessibilityLabel)"
      if coordinator.lastImages[index] != imageKey {
        let configuration = NSImage.SymbolConfiguration(
          pointSize: BrowserChromeLayout.chromeSymbolSize,
          weight: .medium)
        let image = NSImage(
          systemSymbolName: segment.systemImage,
          accessibilityDescription: segment.accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        control.setImage(image, forSegment: index)
        coordinator.lastImages[index] = imageKey
      }

      control.setWidth(height, forSegment: index)
      control.setEnabled(segment.isEnabled, forSegment: index)
      control.setToolTip(segment.accessibilityLabel, forSegment: index)
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: (Int) -> Void
    var lastImages: [String?] = []

    init(action: @escaping (Int) -> Void) {
      self.action = action
    }

    @objc func activateSegment(_ sender: NSSegmentedControl) {
      let index = sender.selectedSegment
      guard index >= 0 else { return }
      action(index)
    }
  }
}

/// A standalone native glass-bezel button used when the sidebar is collapsed.
struct NativeGlassIconButton: NSViewRepresentable {
  let systemImage: String
  let accessibilityLabel: String
  let action: () -> Void

  init(
    systemImage: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(frame: .zero)
    configure(button)
    button.target = context.coordinator
    button.action = #selector(Coordinator.activate(_:))
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    configure(button)
  }

  private func configure(_ button: NSButton) {
    button.setButtonType(.momentaryPushIn)
    let configuration = NSImage.SymbolConfiguration(
      pointSize: BrowserChromeLayout.chromeSymbolSize,
      weight: .medium)
    button.image = NSImage(
      systemSymbolName: systemImage,
      accessibilityDescription: accessibilityLabel
    )?.withSymbolConfiguration(configuration)
    button.imagePosition = .imageOnly
    button.bezelStyle = .glass
    button.borderShape = .circle
    button.isBordered = true
    button.symbolConfiguration = configuration
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .vertical)
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void

    init(action: @escaping () -> Void) {
      self.action = action
    }

    @objc func activate(_ sender: NSButton) {
      action()
    }
  }
}
