//
//  NativeChromeControls.swift
//  NativeBrowser
//
//  Small AppKit bridges for the icon-only controls in browser chrome.
//

import AppKit
import SwiftUI

struct NativeChromeButton: Equatable {
  let systemImage: String
  let accessibilityLabel: String
  let isEnabled: Bool
}

/// Hosts independent native glass buttons in one container so nearby glass
/// effects can merge without introducing segmented-control dividers.
struct NativeGlassButtonGroup: NSViewRepresentable {
  let buttons: [NativeChromeButton]
  let height: CGFloat
  let action: (Int) -> Void

  init(
    buttons: [NativeChromeButton],
    height: CGFloat = BrowserChromeLayout.chromeControlHeight,
    action: @escaping (Int) -> Void
  ) {
    self.buttons = buttons
    self.height = height
    self.action = action
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action, imageKeys: Array(repeating: nil, count: buttons.count))
  }

  func makeNSView(context: Context) -> NSGlassEffectContainerView {
    let container = NSGlassEffectContainerView(frame: .zero)
    container.spacing = BrowserChromeLayout.chromeGlassContainerSpacing

    let stack = NSStackView(frame: .zero)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = BrowserChromeLayout.chromeGlassButtonStackSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false

    for (index, descriptor) in buttons.enumerated() {
      let button = NSButton(frame: CGRect(x: 0, y: 0, width: height, height: height))
      button.tag = index
      button.target = context.coordinator
      button.action = #selector(Coordinator.activate(_:))
      configureNativeGlassButton(
        button,
        descriptor: descriptor,
        height: height,
        imageKey: &context.coordinator.imageKeys[index])
      button.widthAnchor.constraint(equalToConstant: height).isActive = true
      button.heightAnchor.constraint(equalToConstant: height).isActive = true
      stack.addArrangedSubview(button)
    }

    container.contentView = stack
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  func updateNSView(_ container: NSGlassEffectContainerView, context: Context) {
    context.coordinator.action = action
    container.spacing = BrowserChromeLayout.chromeGlassContainerSpacing

    guard let stack = container.contentView as? NSStackView,
      stack.arrangedSubviews.count == buttons.count
    else {
      return
    }

    for (index, view) in stack.arrangedSubviews.enumerated() {
      guard let button = view as? NSButton else { continue }
      button.tag = index
      configureNativeGlassButton(
        button,
        descriptor: buttons[index],
        height: height,
        imageKey: &context.coordinator.imageKeys[index])
    }
  }

  static func dismantleNSView(
    _ container: NSGlassEffectContainerView,
    coordinator: Coordinator
  ) {
    container.contentView = nil
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: (Int) -> Void
    var imageKeys: [String?]

    init(action: @escaping (Int) -> Void, imageKeys: [String?]) {
      self.action = action
      self.imageKeys = imageKeys
    }

    @objc func activate(_ sender: NSButton) {
      action(sender.tag)
    }
  }
}

/// A standalone button with the same native glass presentation used by groups.
struct NativeGlassIconButton: NSViewRepresentable {
  let button: NativeChromeButton
  let height: CGFloat
  let action: () -> Void

  init(
    systemImage: String,
    accessibilityLabel: String,
    height: CGFloat = BrowserChromeLayout.chromeControlHeight,
    action: @escaping () -> Void
  ) {
    self.button = NativeChromeButton(
      systemImage: systemImage,
      accessibilityLabel: accessibilityLabel,
      isEnabled: true)
    self.height = height
    self.action = action
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  func makeNSView(context: Context) -> NSButton {
    let view = NSButton(frame: CGRect(x: 0, y: 0, width: height, height: height))
    view.target = context.coordinator
    view.action = #selector(Coordinator.activate(_:))
    configureNativeGlassButton(
      view,
      descriptor: button,
      height: height,
      imageKey: &context.coordinator.imageKey)
    return view
  }

  func updateNSView(_ view: NSButton, context: Context) {
    context.coordinator.action = action
    configureNativeGlassButton(
      view,
      descriptor: button,
      height: height,
      imageKey: &context.coordinator.imageKey)
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void
    var imageKey: String?

    init(action: @escaping () -> Void) {
      self.action = action
    }

    @objc func activate(_ sender: NSButton) {
      action()
    }
  }
}

@MainActor
private func configureNativeGlassButton(
  _ button: NSButton,
  descriptor: NativeChromeButton,
  height: CGFloat,
  imageKey: inout String?
) {
  button.setButtonType(.momentaryPushIn)
  button.imagePosition = .imageOnly
  button.bezelStyle = .glass
  button.borderShape = .circle
  button.isBordered = true
  button.isEnabled = descriptor.isEnabled
  button.setContentHuggingPriority(.required, for: .horizontal)
  button.setContentHuggingPriority(.required, for: .vertical)
  button.setContentCompressionResistancePriority(.required, for: .horizontal)
  button.setContentCompressionResistancePriority(.required, for: .vertical)
  button.toolTip = descriptor.accessibilityLabel
  button.setAccessibilityLabel(descriptor.accessibilityLabel)

  let key = "\(descriptor.systemImage)|\(descriptor.accessibilityLabel)"
  if imageKey != key {
    let configuration = NSImage.SymbolConfiguration(
      pointSize: BrowserChromeLayout.chromeSymbolSize,
      weight: .medium)
    button.image = NSImage(
      systemSymbolName: descriptor.systemImage,
      accessibilityDescription: descriptor.accessibilityLabel
    )?.withSymbolConfiguration(configuration)
    button.symbolConfiguration = configuration
    imageKey = key
  }

  if button.frame.size != CGSize(width: height, height: height) {
    button.setFrameSize(CGSize(width: height, height: height))
  }
}
