//
//  SpotlightView.swift
//  NativeBrowser
//
//  Native new-tab command surface. Its AppKit text field keeps the browser's
//  normal field-editor behavior for IME composition and keyboard selection.
//

import AppKit
import SwiftUI

struct SpotlightView: View {
  let onSelect: (SpotlightMode) -> Void
  let onDismiss: () -> Void

  @State private var text = ""
  @State private var selectedIndex = 0

  private var suggestions: [SpotlightMode] {
    SpotlightMode.suggestions(for: text)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture(perform: onDismiss)

        HStack(spacing: 16) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28)
            .accessibilityHidden(true)

          SpotlightInputField(
            text: text,
            onChange: { text = $0; selectedIndex = 0 },
            onSubmit: submitSelected,
            onEscape: onDismiss,
            onMove: moveSelection)
            .frame(height: 32)
            .accessibilityLabel("Spotlight search or website")
        }
        .padding(.horizontal, 23)
        .frame(height: 66)
        .frame(maxWidth: .infinity)
        .browserChromeGlassSurface(in: Capsule())
        .overlay {
          Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
          if !suggestions.isEmpty {
            VStack(spacing: 4) {
              ForEach(Array(suggestions.enumerated()), id: \.offset) { index, mode in
                Button {
                  onSelect(mode)
                } label: {
                  HStack(spacing: 14) {
                    Image(systemName: mode.symbolName)
                      .font(.system(size: 18, weight: .medium))
                      .frame(width: 24)
                      .foregroundStyle(index == selectedIndex ? .primary : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(mode.title)
                        .lineLimit(1)
                        .font(.system(size: 15, weight: .medium))
                      Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                  }
                  .padding(.horizontal, 16)
                  .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                  .background {
                    if index == selectedIndex {
                      RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.24))
                    }
                  }
                  .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                  if hovering { selectedIndex = index }
                }
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .browserChromeGlassSurface(
              in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .offset(y: 76)
          }
        }
        .frame(width: min(geometry.size.width - 48, 720))
        .offset(y: -geometry.size.height / 6)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityIdentifier("spotlight")
  }

  private func submitSelected() {
    guard suggestions.indices.contains(selectedIndex) else { return }
    onSelect(suggestions[selectedIndex])
  }

  private func moveSelection(_ direction: Int) {
    guard !suggestions.isEmpty else { return }
    selectedIndex = (selectedIndex + direction + suggestions.count) % suggestions.count
  }
}

private struct SpotlightInputField: NSViewRepresentable {
  let text: String
  let onChange: (String) -> Void
  let onSubmit: () -> Void
  let onEscape: () -> Void
  let onMove: (Int) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NativeBrowserAddressField {
    let field = NativeBrowserAddressField()
    field.delegate = context.coordinator
    field.placeholderString = "Search or enter a website"
    field.font = .systemFont(ofSize: 20)
    field.textColor = .labelColor
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.isEditable = true
    field.isSelectable = true
    field.stringValue = text
    DispatchQueue.main.async { [weak field] in
      guard let field, field.window != nil else { return }
      field.focusAndSelectAll()
    }
    return field
  }

  func updateNSView(_ field: NativeBrowserAddressField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: SpotlightInputField

    init(parent: SpotlightInputField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.onChange(field.stringValue)
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy selector: Selector
    ) -> Bool {
      // Return may still be committing a marked IME candidate.
      if textView.hasMarkedText() { return false }
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onEscape()
      case #selector(NSResponder.moveUp(_:)):
        parent.onMove(-1)
      case #selector(NSResponder.moveDown(_:)):
        parent.onMove(1)
      default:
        return false
      }
      return true
    }
  }
}
