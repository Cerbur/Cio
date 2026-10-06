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
  static let suggestionHorizontalInset: CGFloat = 12
  static let suggestionIconWidth: CGFloat = 24
  static let suggestionIconSpacing: CGFloat = 12
  static var suggestionIconCenter: CGFloat {
    listInset + suggestionHorizontalInset + suggestionIconWidth / 2
  }
  static var suggestionTextInset: CGFloat {
    listInset + suggestionHorizontalInset + suggestionIconWidth + suggestionIconSpacing
  }
  static func panelHeight(rowCount: Int) -> CGFloat {
    height + (rowCount > 0
      ? 1 + 2 * listInset + CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * rowSpacing : 0)
  }
  static var maximumHeight: CGFloat { panelHeight(rowCount: AddressAutocompleteModel.rowLimit) }
  static let height = AddressCapsuleInteraction.controlDiameter
  static let cornerRadius = height / 2
  static let unfocusedWidthRatio: CGFloat = 0.38
  static let focusedWidthRatio: CGFloat = 0.45
  static let faviconSize: CGFloat = 16
  static let endControlHitDiameter = AddressCapsuleInteraction.controlDiameter
  static let textIdealHeight: CGFloat = 22
  /// Reserve matching space at both ends so idle text is centred in the pill.
  static let endControlWidth: CGFloat = 40
}

struct ToolbarAddressFieldView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  /// Nil follows workspace selection; a UUID keeps every address action bound
  /// to that pane's tab, even while another pane is selected.
  var tabID: UUID? = nil
  @ObservedObject var interaction: BrowserInteractionState
  @ObservedObject var autocomplete: AddressAutocompleteModel
  @ObservedObject var presentation: ToolbarPresentationState
  @ObservedObject var siteInformation: AddressSiteInformationState
  @State private var hoverGate = SpotlightHoverGate()
  var onFocusChange: (BrowserSession, Bool) -> Void
  var onReloadOrStop: (BrowserSession) -> Void
  var onSiteInformationToggle: (BrowserSession) -> Void
  var onCertificate: (SiteInformation) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var session: BrowserSession? {
    if let tabID { return workspace.session(for: tabID) }
    return workspace.selectedSession
  }

  private var rowCount: Int { interaction.isFocused ? autocomplete.suggestions.count : 0 }

  private var isActiveSplitPane: Bool {
    guard let session, let split = workspace.activeSplit else { return false }
    return split.contains(session.tabID) && workspace.selectedTabID == session.tabID
      && !workspace.isSpotlightPresented
  }

  private var focusRingOpacity: Double {
    interaction.isFocused ? 1 : isActiveSplitPane ? 0.5 : 0
  }

  var body: some View {
    GeometryReader { geometry in
      let width = siteInformation.width(in: geometry.size.width, focused: interaction.isFocused)
      let height = siteInformation.height(rowCount: rowCount)
      let radius: CGFloat = siteInformation.isPresented ? 24
        : rowCount > 0 ? 20 : AddressCapsuleLayout.cornerRadius
      if let session {
        VStack(spacing: 0) {
          addressField(for: session, width: width)
          if siteInformation.isPresented {
            AddressSiteInformationView(state: siteInformation,
                                       onCertificate: onCertificate)
              .transition(reduceMotion ? .opacity
                : .scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
          } else if rowCount > 0 {
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
        .background {
          ToolbarGlassSurface(presentation: presentation, cornerRadius: radius)
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(rowCount > 0 || siteInformation.isPresented ? 0.18 : 0),
                radius: 16, y: 8)
        .overlay {
          NativeAddressFocusRing(cornerRadius: radius)
            .padding(-NativeAddressFocusRing.inset)
            // Keep the native ring mounted so losing focus can finish fading
            // out. Scope the animation to opacity, preserving capsule geometry.
            .animation(reduceMotion ? nil : .easeInOut(duration: AnimationValues.AddressField.focusRingDuration)) { content in
              content.opacity(focusRingOpacity)
            }
            .allowsHitTesting(false)
        }
        // One visibility animation for the entire first-level capsule, after
        // glass/content/focus-ring composition and before the overlay host frame.
        .modifier(ToolbarComponentVisibility(presentation: presentation))
        .frame(width: geometry.size.width, alignment: .top)
      }
    }
    .frame(height: max(AddressCapsuleLayout.maximumHeight,
                       AddressCapsuleLayout.height + AddressSiteInformationState.contentHeight), alignment: .top)
    .allowsHitTesting(presentation.isVisible)
    .accessibilityHidden(!presentation.isVisible)
    .animation(reduceMotion ? nil : .spring(response: AnimationValues.AddressField.expansionResponse, dampingFraction: AnimationValues.AddressField.expansionDamping),
               value: interaction.isFocused)
    .animation(reduceMotion ? nil : .spring(response: AnimationValues.AddressField.expansionResponse, dampingFraction: AnimationValues.AddressField.expansionDamping),
               value: rowCount)
    .animation(reduceMotion ? nil : .spring(response: AnimationValues.AddressField.siteInformationResponse, dampingFraction: AnimationValues.AddressField.siteInformationDamping),
               value: siteInformation.isPresented)
    .onChange(of: interaction.isFocused) { _, focused in
      if focused, let session { autocomplete.begin(session.addressField.editText) }
      else { autocomplete.end() }
      hoverGate.reset(to: NSEvent.mouseLocation)
    }
    .onChange(of: session?.id) { _, _ in autocomplete.end() }
  }

  private func addressField(for session: BrowserSession, width: CGFloat) -> some View {
    let isExpanded = rowCount > 0
    let textInset = isExpanded ? AddressCapsuleLayout.suggestionTextInset : AddressCapsuleLayout.endControlWidth
    return ZStack(alignment: .leading) {
      AddressField(
        model: session.addressField,
        isFocused: interaction.isFocused,
        acceptsInteraction: { presentation.isVisible },
        completion: autocomplete.isActive && autocomplete.hasUserEdited ? autocomplete.input : nil,
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
        onSiteInformationToggle: { onSiteInformationToggle(session) },
        onFocusChange: { onFocusChange(session, $0) }
      )
      .frame(width: max(0, width - textInset - AddressCapsuleLayout.endControlWidth),
             height: AddressCapsuleLayout.textIdealHeight)
      // Keep the native editor mounted, but hide its idle text immediately so
      // it cannot appear underneath the compact domain's fade-in.
      .animation(nil) { content in
        content.opacity(interaction.isFocused ? 1 : 0)
      }
      .overlay {
        AddressCompactText(model: session.addressField, isFocused: interaction.isFocused)
      }
      .padding(.leading, textInset)
      .accessibilityIdentifier("address-input")

      Group {
        if isExpanded, let suggestion = autocomplete.selectedSuggestion {
          suggestionIcon(suggestion, size: AddressCapsuleLayout.faviconSize)
        } else {
          AddressFaviconButton(session: session) { onSiteInformationToggle(session) }
            .id(session.id)
        }
      }
        .frame(width: AddressCapsuleLayout.endControlHitDiameter,
               height: AddressCapsuleLayout.endControlHitDiameter)
        .contentShape(Circle())
        .zIndex(1)
        .accessibilityHidden(isExpanded)
        .position(x: isExpanded ? AddressCapsuleLayout.suggestionIconCenter : AddressCapsuleLayout.cornerRadius,
                  y: AddressCapsuleLayout.height / 2)

      ZStack {
        if !isExpanded {
          AddressReloadButton(session: session, onReloadOrStop: { onReloadOrStop(session) })
            .id(session.id)
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
      }
        .frame(width: AddressCapsuleLayout.endControlHitDiameter,
               height: AddressCapsuleLayout.endControlHitDiameter)
        .contentShape(Circle())
        .zIndex(1)
        .allowsHitTesting(!isExpanded)
        .accessibilityHidden(isExpanded)
        .position(x: width - AddressCapsuleLayout.cornerRadius,
                  y: AddressCapsuleLayout.height / 2)
    }
    .frame(width: width, height: AddressCapsuleLayout.height)
  }

  private func suggestionRow(_ suggestion: SpotlightSuggestion, index: Int,
                             session: BrowserSession) -> some View {
    Button { submit(session: session, mode: suggestion.mode) } label: {
      HStack(spacing: AddressCapsuleLayout.suggestionIconSpacing) {
        suggestionIcon(suggestion, size: 18)
          .frame(width: AddressCapsuleLayout.suggestionIconWidth)
        VStack(alignment: .leading, spacing: 2) {
          Text(suggestion.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
          if !suggestion.subtitle.isEmpty {
            Text(suggestion.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, AddressCapsuleLayout.suggestionHorizontalInset)
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

  @ViewBuilder
  private func suggestionIcon(_ suggestion: SpotlightSuggestion, size: CGFloat) -> some View {
    if case .website(let url) = suggestion.mode {
      TabFaviconView(pageURL: url, session: nil, size: size)
    } else {
      Image(systemName: suggestion.symbolName)
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(.secondary)
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

/// The idle domain leaves to the left and returns moving right from that same
/// offset, while the native field retains ownership of editing and selection.
private struct AddressCompactText: View {
  @ObservedObject var model: AddressFieldModel
  var isFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let domain = model.compactDisplayText(for: model.committedURL)
    ZStack {
      if !isFocused {
        Text(domain.isEmpty ? AddressFieldModel.placeholder : domain)
          .font(.system(size: 13))
          .foregroundStyle(domain.isEmpty ? Color.secondary : Color.primary)
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, 2)
          .transition(reduceMotion ? .opacity
            : .offset(x: AnimationValues.AddressField.compactTextOffset).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .animation(reduceMotion ? nil : .easeOut(duration: AnimationValues.AddressField.buttonFocusDuration), value: isFocused)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Matches the reload control's hover timing and scale, keeping the circular
/// hit area fixed while only the favicon gently grows and settles back.
private struct AddressFaviconButton: View {
  @ObservedObject var session: BrowserSession
  var onSiteInformationToggle: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    Button(action: onSiteInformationToggle) {
      TabFaviconView(pageURL: session.url, session: session, size: AddressCapsuleLayout.faviconSize)
        .scaleEffect(isHovered ? AnimationValues.AddressField.hoverScale : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: AnimationValues.AddressField.hoverDuration), value: isHovered)
        .frame(width: AddressCapsuleLayout.endControlHitDiameter,
               height: AddressCapsuleLayout.endControlHitDiameter)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("网站信息")
    .accessibilityLabel("网站信息")
    .accessibilityIdentifier("address-site-information-button")
  }
}

/// Loading state comes from the selected session; the idle symbol rests upright.
private struct AddressReloadButton: View {
  @ObservedObject var session: BrowserSession
  var onReloadOrStop: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var rotationStart = Date()
  // Capture the cycle at load start so changing Settings cannot jump its phase.
  @State private var rotationDuration = AnimationValues.AddressField.reloadRotationDuration
  @State private var isHovered = false

  var body: some View {
    Button(action: onReloadOrStop) {
      Group {
        if session.isLoading && !reduceMotion {
          TimelineView(.animation) { context in
            reloadSymbol
              .rotationEffect(.degrees(
                context.date.timeIntervalSince(rotationStart) / rotationDuration * 360))
          }
        } else {
          reloadSymbol
        }
      }
      .frame(width: AddressCapsuleLayout.endControlHitDiameter,
             height: AddressCapsuleLayout.endControlHitDiameter)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(session.isLoading ? "Stop" : "Reload")
    .accessibilityLabel(session.isLoading ? "Stop" : "Reload")
    .accessibilityIdentifier("address-reload")
    .onChange(of: session.isLoading) { _, isLoading in
      if isLoading {
        rotationStart = Date()
        rotationDuration = AnimationValues.AddressField.reloadRotationDuration
      }
    }
  }

  private var reloadSymbol: some View {
    let highlightsHover = isHovered && !session.isLoading
    let hoverColor = colorScheme == .dark ? Color.white : Color.black
    return Image(systemName: "arrow.triangle.2.circlepath")
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(highlightsHover ? hoverColor : Color.secondary)
      .scaleEffect(highlightsHover ? AnimationValues.AddressField.hoverScale : 1)
      .animation(reduceMotion ? nil : .easeInOut(duration: AnimationValues.AddressField.hoverDuration),
                 value: highlightsHover)
  }
}

/// AppKit draws the system focus ring from the capsule mask, including the
/// user's accent colour. The same ring identifies the active split pane at a
/// lower opacity; address editing always takes precedence at full strength.
private struct NativeAddressFocusRing: NSViewRepresentable {
  static let inset: CGFloat = 6

  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> FocusRingView {
    let view = FocusRingView()
    view.cornerRadius = cornerRadius
    return view
  }

  func updateNSView(_ view: FocusRingView, context: Context) {
    view.cornerRadius = cornerRadius
  }

  final class FocusRingView: NSView {
    var cornerRadius: CGFloat = AddressCapsuleLayout.cornerRadius {
      didSet { if oldValue != cornerRadius { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      NSGraphicsContext.saveGraphicsState()
      let capsule = bounds.insetBy(dx: NativeAddressFocusRing.inset,
                                   dy: NativeAddressFocusRing.inset)
      NSFocusRingPlacement.only.set()
      NSBezierPath(roundedRect: capsule, xRadius: cornerRadius,
                   yRadius: cornerRadius).fill()
      NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
