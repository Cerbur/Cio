//
//  ToolbarAddressFieldView.swift
//  NativeBrowser
//
//  The toolbar's address capsule: the tab favicon, native address field,
//  reload/stop control, and the capsule glass that carries the focus ring.
//
//  BrowserToolbarController positions this view above the Chromium view;
//  the capsule's appearance lives here, while toolbar events own its focus state.
//

import AppKit
import SwiftUI

/// Geometry of the address capsule.
///
/// The corner radius is half the height, making each end of the pill a circle.
/// The favicon and reload icon sit on the respective cap centres.
enum AddressCapsuleLayout {
  static let rowHeight: CGFloat = 48
  static let rowSpacing: CGFloat = 4
  static let listInset: CGFloat = 8
  static func panelHeight(rowCount: Int) -> CGFloat {
    height + (rowCount > 0
      ? 1 + 2 * listInset + CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * rowSpacing : 0)
  }
  static var maximumHeight: CGFloat { panelHeight(rowCount: AddressAutocompleteModel.rowLimit) }
  static let height: CGFloat = 36
  static let cornerRadius = height / 2
  static let unfocusedWidthRatio: CGFloat = 0.38
  static let focusedWidthRatio: CGFloat = 0.45
  static let faviconSize: CGFloat = 16
  static let reloadHitDiameter = height
  static let textIdealHeight: CGFloat = 22
  /// Reserve matching space at both ends so idle text is centred in the pill.
  static let endControlWidth: CGFloat = 40
}

struct ToolbarAddressFieldView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  @ObservedObject var interaction: BrowserInteractionState
  @ObservedObject var autocomplete: AddressAutocompleteModel
  @ObservedObject var presentation: ToolbarPresentationState
  @State private var hoverGate = SpotlightHoverGate()
  var onFocusChange: (BrowserSession, Bool) -> Void
  var onReloadOrStop: (BrowserSession) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var rowCount: Int { interaction.isFocused ? autocomplete.suggestions.count : 0 }

  var body: some View {
    GeometryReader { geometry in
      let widthRatio = interaction.isFocused
        ? 1 : AddressCapsuleLayout.unfocusedWidthRatio / AddressCapsuleLayout.focusedWidthRatio
      let width = geometry.size.width * widthRatio
      let height = AddressCapsuleLayout.panelHeight(rowCount: rowCount)
      let radius: CGFloat = rowCount > 0 ? 20 : AddressCapsuleLayout.cornerRadius
      if let session = workspace.selectedSession {
        VStack(spacing: 0) {
          addressField(for: session, width: width)
          if rowCount > 0 {
            Divider().padding(.horizontal, 16)
            VStack(spacing: AddressCapsuleLayout.rowSpacing) {
              ForEach(Array(autocomplete.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                suggestionRow(suggestion, index: index, session: session)
              }
            }
            .padding(AddressCapsuleLayout.listInset)
            .transition(.opacity)
          }
        }
        .frame(width: width, height: height, alignment: .top)
        .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .opacity(presentation.isVisible ? 1 : 0)
        .background {
          ToolbarGlassSurface(presentation: presentation, cornerRadius: radius)
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(rowCount > 0 ? 0.18 : 0), radius: 16, y: 8)
        .overlay {
          NativeAddressFocusRing(isFocused: interaction.isFocused, cornerRadius: radius)
            .padding(-NativeAddressFocusRing.inset)
            .allowsHitTesting(false)
        }
        .frame(width: geometry.size.width, alignment: .top)
      }
    }
    .frame(height: AddressCapsuleLayout.maximumHeight, alignment: .top)
    .allowsHitTesting(presentation.isVisible)
    .accessibilityHidden(!presentation.isVisible)
    .animation(reduceMotion ? nil : .spring(response: 0.31, dampingFraction: 0.68),
               value: interaction.isFocused)
    .animation(reduceMotion ? nil : .spring(response: 0.31, dampingFraction: 0.68),
               value: rowCount)
    .onChange(of: interaction.isFocused) { _, focused in
      if focused, let session = workspace.selectedSession { autocomplete.begin(session.addressField.editText) }
      else { autocomplete.end() }
      hoverGate.reset(to: NSEvent.mouseLocation)
    }
    .onChange(of: workspace.selectedSession?.id) { _, _ in autocomplete.end() }
  }

  private func addressField(for session: BrowserSession, width: CGFloat) -> some View {
    ZStack {
      AddressField(
        model: session.addressField,
        isFocused: interaction.isFocused,
        completion: autocomplete.isActive ? autocomplete.input : nil,
        dropdownHeight: AddressCapsuleLayout.panelHeight(rowCount: rowCount) - AddressCapsuleLayout.height,
        onChange: { text, isComposing, allowsCompletion in
          session.addressField.userChangedText(text)
          autocomplete.edit(text, isComposing: isComposing, allowsCompletion: allowsCompletion)
          hoverGate.reset(to: NSEvent.mouseLocation)
        },
        onAcceptCompletion: { autocomplete.acceptCompletion() },
        onMove: { autocomplete.move($0) },
        onSubmit: { submit(session: session) },
        onEscape: { autocomplete.end(); session.cancelAddressEditing() },
        onReloadOrStop: { onReloadOrStop(session) },
        onFocusChange: { onFocusChange(session, $0) }
      )
      .frame(width: max(0, width - 2 * AddressCapsuleLayout.endControlWidth),
             height: AddressCapsuleLayout.textIdealHeight)
      .accessibilityIdentifier("address-input")

      TabFaviconView(pageURL: session.url ?? workspace.selectedTab?.url,
                     session: session, size: AddressCapsuleLayout.faviconSize)
        .frame(width: AddressCapsuleLayout.endControlWidth,
               height: AddressCapsuleLayout.height)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .position(x: AddressCapsuleLayout.cornerRadius,
                  y: AddressCapsuleLayout.height / 2)

      AddressReloadButton(session: session, onReloadOrStop: { onReloadOrStop(session) })
        .id(session.id)
        .frame(width: AddressCapsuleLayout.reloadHitDiameter,
               height: AddressCapsuleLayout.reloadHitDiameter)
        .position(x: width - AddressCapsuleLayout.cornerRadius,
                  y: AddressCapsuleLayout.height / 2)
    }
    .frame(width: width, height: AddressCapsuleLayout.height)
  }

  private func suggestionRow(_ suggestion: SpotlightSuggestion, index: Int,
                             session: BrowserSession) -> some View {
    Button { submit(session: session, mode: suggestion.mode) } label: {
      HStack(spacing: 12) {
        if case .website(let url) = suggestion.mode {
          TabFaviconView(pageURL: url, session: nil, size: 18).frame(width: 24)
        } else {
          Image(systemName: suggestion.symbolName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 24)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(suggestion.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
          if !suggestion.subtitle.isEmpty {
            Text(suggestion.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: AddressCapsuleLayout.rowHeight, alignment: .leading)
      .background {
        if index == autocomplete.selectedIndex {
          RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.24))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("address-suggestion-\(index)")
    .accessibilityAddTraits(index == autocomplete.selectedIndex ? .isSelected : [])
    .onContinuousHover { phase in
      guard case .active = phase else { return }
      if hoverGate.moved(to: NSEvent.mouseLocation) { autocomplete.select(index) }
    }
  }

  private func submit(session: BrowserSession, mode: SpotlightMode? = nil) {
    guard let mode = mode ?? autocomplete.selectedMode else {
      session.submitAddressField()
      autocomplete.end()
      return
    }
    session.addressField.endEditing()
    if case .openTab(let url) = mode.action { session.load(url) }
    autocomplete.end()
    session.focusPage()
  }

}

/// Loading state comes from the selected session; the idle symbol rests upright.
private struct AddressReloadButton: View {
  @ObservedObject var session: BrowserSession
  var onReloadOrStop: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var rotationStart = Date()
  @State private var isHovered = false

  var body: some View {
    Button(action: onReloadOrStop) {
      Group {
        if session.isLoading && !reduceMotion {
          TimelineView(.animation) { context in
            reloadSymbol
              .rotationEffect(.degrees(
                context.date.timeIntervalSince(rotationStart) / 0.9 * 360))
          }
        } else {
          reloadSymbol
        }
      }
      .frame(width: AddressCapsuleLayout.reloadHitDiameter,
             height: AddressCapsuleLayout.reloadHitDiameter)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(session.isLoading ? "Stop" : "Reload")
    .accessibilityLabel(session.isLoading ? "Stop" : "Reload")
    .accessibilityIdentifier("address-reload")
    .onChange(of: session.isLoading) { _, isLoading in
      if isLoading { rotationStart = Date() }
    }
  }

  private var reloadSymbol: some View {
    let highlightsHover = isHovered && !session.isLoading
    return Image(systemName: "arrow.triangle.2.circlepath")
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(highlightsHover ? Color.black : Color.secondary)
      .scaleEffect(highlightsHover ? 16.0 / 14.0 : 1)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15),
                 value: highlightsHover)
  }
}

/// A shared AppKit outline keeps the focus colour and width consistent across
/// the capsule and suggestion panel. Its bounds follow every spring frame.
private struct NativeAddressFocusRing: NSViewRepresentable {
  static let inset: CGFloat = 6
  static let lineWidth: CGFloat = 3
  static let colour = NSColor(srgbRed: 0.58, green: 0.70, blue: 0.84, alpha: 1)

  let isFocused: Bool
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> FocusRingView {
    let view = FocusRingView()
    view.cornerRadius = cornerRadius
    view.isFocused = isFocused
    return view
  }

  func updateNSView(_ view: FocusRingView, context: Context) {
    view.cornerRadius = cornerRadius
    view.isFocused = isFocused
  }

  final class FocusRingView: NSView {
    var cornerRadius: CGFloat = AddressCapsuleLayout.cornerRadius {
      didSet { if oldValue != cornerRadius { needsDisplay = true } }
    }
    var isFocused = false {
      didSet {
        if oldValue != isFocused { needsDisplay = true }
      }
    }

    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      guard isFocused else { return }
      NSGraphicsContext.saveGraphicsState()
      let capsule = bounds.insetBy(dx: NativeAddressFocusRing.inset,
                                   dy: NativeAddressFocusRing.inset)
      // Centre the stroke outside the glass, preserving the system halo's
      // footprint without its backdrop-dependent colour and compositing.
      let offset = NativeAddressFocusRing.lineWidth / 2
      let outline = NSBezierPath(roundedRect: capsule.insetBy(dx: -offset, dy: -offset),
                                 xRadius: cornerRadius + offset,
                                 yRadius: cornerRadius + offset)
      outline.lineWidth = NativeAddressFocusRing.lineWidth
      NativeAddressFocusRing.colour.setStroke()
      outline.stroke()
      NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
