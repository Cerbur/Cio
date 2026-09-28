//
//  SpotlightView.swift
//  NativeBrowser
//
//  Native new-tab command surface. Its AppKit text field keeps the browser's
//  normal field-editor behavior for IME composition and keyboard selection.
//

import AppKit
import SwiftUI

@MainActor
final class SpotlightPresentationState: ObservableObject {
  @Published var isPresented = true
}

struct SpotlightView: View {
  @ObservedObject var presentation: SpotlightPresentationState
  let onSelect: (SpotlightMode) -> Void
  let onDismiss: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var text = ""
  @State private var selectedIndex = 0
  @State private var glassProgress: CGFloat = 0
  @State private var glassOpacity = 0.0
  @State private var isContentVisible = false
  @State private var panelHeight: CGFloat = 66
  @State private var focusGeneration = 0

  private let expandedCornerRadius: CGFloat = 33
  private let suggestionInset: CGFloat = 8

  private var suggestions: [SpotlightMode] {
    SpotlightMode.suggestions(for: text)
  }

  private var isExpanded: Bool { !suggestions.isEmpty }

  private var suggestionCornerRadius: CGFloat { expandedCornerRadius - suggestionInset }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 17 + (expandedCornerRadius - 17) * glassProgress, style: .continuous)
  }

  var body: some View {
    GeometryReader { geometry in
      let panelWidth = min(geometry.size.width - 48, 720)
      let panelTop = max(16, geometry.size.height / 3 - 33)
      // Both current suggestion modes fit inside this fixed glass footprint.
      // Only its visible outline changes, so the blur is stable while typing.
      let glassSourceHeight = max(panelHeight, 200)
      let glassWidth = 34 + (panelWidth - 34) * glassProgress
      let glassHeight = 34 + (panelHeight - 34) * glassProgress
      // Close toward the original capsule center, even after suggestions expand the panel.
      let glassOffset: CGFloat = 16 * (1 - glassProgress)
      ZStack(alignment: .top) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture(perform: onDismiss)

        ZStack(alignment: .top) {
          Color.clear
            .frame(width: panelWidth, height: glassSourceHeight)
            .background {
              RoundedRectangle(cornerRadius: expandedCornerRadius, style: .continuous)
                .fill(.thinMaterial).opacity(0.1)
            }
            // Keep this backdrop fixed so its blur stays stable while suggestions grow.
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: expandedCornerRadius, style: .continuous))
            // Flatten the native glass before masking; otherwise its backdrop
            // can still draw outside the capsule on top of the browser page.
            .compositingGroup()
            .mask(alignment: .top) {
              panelShape
                .frame(width: glassWidth, height: glassHeight)
                .offset(y: glassOffset)
            }
            .opacity(glassOpacity)
            .shadow(color: .black.opacity(0.38 * glassOpacity), radius: 16, y: 8)
            .overlay(alignment: .top) {
              panelShape.strokeBorder(.white.opacity(0.2 * glassOpacity), lineWidth: 1)
                .frame(width: glassWidth, height: glassHeight)
                .offset(y: glassOffset)
                .allowsHitTesting(false)
            }
            .allowsHitTesting(false)

          // The native refractive edge follows the same spring as the visible outline.
          Color.clear
            .frame(width: glassWidth, height: glassHeight)
            .glassEffect(.clear, in: panelShape)
            .offset(y: glassOffset)
            .opacity(glassOpacity)
            .allowsHitTesting(false)

          panelContents
            .frame(width: panelWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
              withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                panelHeight = height
              }
            }
            // Reveal text and suggestions only inside the animated glass outline.
            .mask(alignment: .top) {
              panelShape
                .frame(width: glassWidth, height: glassHeight)
                .offset(y: glassOffset)
            }
            .opacity(isContentVisible ? 1 : 0)
            .allowsHitTesting(isContentVisible)
        }
        .frame(width: panelWidth)
        // Suggestions grow downward from the capsule's top edge; closing
        // always returns the glass to the original capsule center.
        .padding(.top, panelTop)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { animatePresentation(presentation.isPresented) }
    .onChange(of: presentation.isPresented) { _, presented in animatePresentation(presented) }
    .accessibilityIdentifier("spotlight")
  }

  private var panelContents: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 28)
          .accessibilityHidden(true)

        SpotlightInputField(
          text: text,
          focusGeneration: focusGeneration,
          onChange: { text = $0; selectedIndex = 0 },
          onSubmit: submitSelected,
          onEscape: onDismiss,
          onMove: moveSelection)
          .frame(height: 32)
          .accessibilityLabel("Spotlight search or website")
      }
      .padding(.horizontal, 23)
      .frame(height: 66)

      if isExpanded {
        Divider()
          .padding(.horizontal, 20)

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
                  RoundedRectangle(cornerRadius: suggestionCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.24))
                }
              }
              .contentShape(RoundedRectangle(cornerRadius: suggestionCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
              if hovering { selectedIndex = index }
            }
          }
        }
        .padding(suggestionInset)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
      }
    }
  }

  private func animatePresentation(_ presented: Bool) {
    if presented {
      if reduceMotion {
        glassProgress = 1
      } else {
        withAnimation(.spring(response: 0.31, dampingFraction: 0.68)) {
          glassProgress = 1
        }
      }
      withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.12)) {
        glassOpacity = 1
      }
      withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.12).delay(reduceMotion ? 0 : 0.067)) {
        isContentVisible = true
      }
      focusGeneration += 1
    } else {
      withAnimation(.easeIn(duration: 0.025)) { isContentVisible = false }
      if reduceMotion {
        glassProgress = 0
      } else {
        withAnimation(.easeInOut(duration: 0.13)) { glassProgress = 0 }
      }
      withAnimation(.easeIn(duration: 0.03).delay(reduceMotion ? 0 : 0.1)) {
        glassOpacity = 0
      }
    }
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
  let focusGeneration: Int
  let onChange: (String) -> Void
  let onSubmit: () -> Void
  let onEscape: () -> Void
  let onMove: (Int) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NativeBrowserAddressField {
    let field = NativeBrowserAddressField()
    context.coordinator.lastFocusGeneration = focusGeneration
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
    if context.coordinator.lastFocusGeneration != focusGeneration {
      context.coordinator.lastFocusGeneration = focusGeneration
      DispatchQueue.main.async { [weak field] in
        guard let field, field.window != nil else { return }
        field.focusAndSelectAll()
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: SpotlightInputField
    var lastFocusGeneration = 0

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
