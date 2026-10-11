import AppKit
import SwiftUI

/// A value snapshot owned by one runtime session, never shared or persisted.
public struct BrowserFindState: Equatable {
  public var query = ""
  public var isVisible = false
  public var isSearching = false
  public var activeMatch = 0
  public var matchCount: Int?

  public init() {}

  public var canNavigate: Bool {
    !query.isEmpty && !isSearching && (matchCount ?? 0) > 0
  }

  public var resultText: String {
    if query.isEmpty { return "" }
    if isSearching { return "Searching…" }
    guard let matchCount else { return "" }
    return "\(activeMatch) / \(matchCount)"
  }
}

/// Stable native controls inside the owning page, independent of shell chrome.
/// No custom animation: AppKit supplies the search field, material and buttons.
@MainActor
public final class BrowserFindBarView: NSVisualEffectView, NSSearchFieldDelegate {
  public var onQueryChanged: ((String) -> Void)?
  public var onNavigate: ((Bool) -> Void)?
  public var onClose: (() -> Void)?
  public var onFocusChanged: ((Bool) -> Void)?

  private let field = BrowserFindSearchField()
  private let result = NSTextField(labelWithString: "")
  private let previous = BrowserFindButtonHost(symbol: "chevron.up", label: "Previous match",
    help: "Previous match (⇧Return or ⌘⇧G)")
  private let next = BrowserFindButtonHost(symbol: "chevron.down", label: "Next match",
    help: "Next match (Return or ⌘G)")
  private let close = BrowserFindButtonHost(symbol: "xmark", label: "Close Find in Page",
    help: "Close Find in Page (Esc)")
  nonisolated(unsafe) private var escapeMonitor: Any?

  public override var isFlipped: Bool { true }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .popover
    blendingMode = .withinWindow
    wantsLayer = true
    layer?.cornerRadius = BrowserLayout.contentCornerRadius
    layer?.cornerCurve = .continuous
    isHidden = true

    field.placeholderString = "Find in Page"
    field.controlSize = .small
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.delegate = self
    // NSTextField's begin-editing notification may wait for the first edit.
    // Suppress the split selection's deferred page focus as soon as AppKit
    // focuses the native field, before that deferred handoff can run.
    field.onDidFocus = { [weak self] in self?.onFocusChanged?(true) }
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.setAccessibilityLabel("Find in Page")
    field.toolTip = "Find in this page (⌘F)"
    field.searchMenuTemplate = nil

    result.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    result.textColor = .secondaryLabelColor
    result.alignment = .right
    result.lineBreakMode = .byTruncatingTail
    result.setAccessibilityLabel("Find results")

    previous.model.action = { [weak self] in self?.onNavigate?(false) }
    next.model.action = { [weak self] in self?.onNavigate?(true) }
    close.model.action = { [weak self] in self?.onClose?() }
    for view in [field, result, previous, next, close] { addSubview(view) }
    field.nextKeyView = previous
    previous.nextKeyView = next
    next.nextKeyView = close
    close.nextKeyView = field
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  public func apply(_ state: BrowserFindState) {
    // Result callbacks must never replace a live field editor or marked text.
    if field.stringValue != state.query && !hasMarkedText {
      field.stringValue = state.query
    }
    isHidden = !state.isVisible
    result.stringValue = state.resultText
    result.textColor = state.matchCount == 0 && !state.isSearching ? .systemRed : .secondaryLabelColor
    result.toolTip = state.matchCount == 0 && !state.isSearching && !state.query.isEmpty
      ? "No matches" : state.resultText
    result.setAccessibilityValue(result.toolTip ?? "")
    previous.model.isEnabled = state.canNavigate
    next.model.isEnabled = state.canNavigate
    needsLayout = true
  }

  /// Called from a menu command or the native platform adapter. Repeated ⌘F
  /// selects the existing query without restarting a completed search.
  public func focusAndSelect() {
    guard !isHiddenOrHasHiddenAncestor, let window else { return }
    window.makeFirstResponder(field)
    field.selectText(nil)
  }

  public var hasKeyboardFocus: Bool {
    guard let responder = window?.firstResponder else { return false }
    return responder === field || responder === field.currentEditor()
      || (responder as? NSView)?.isDescendant(of: self) == true
  }

  public var hasMarkedText: Bool {
    (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
  }

  /// Escape only belongs to this bar when its editor or its own web page has
  /// focus. Address fields, other panes, DevTools, sheets and IME keep the event.
  public func installEscapeRouting(for pageView: NSView) {
    guard escapeMonitor == nil else { return }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak pageView] event in
      guard let self, let pageView, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            event.window === self.window, self.window?.attachedSheet == nil,
            !self.isHiddenOrHasHiddenAncestor, let responder = self.window?.firstResponder else { return event }
      let ownsPage = (responder as? NSView)?.isDescendant(of: pageView) == true
      guard self.hasKeyboardFocus || ownsPage,
            (responder as? any NSTextInputClient)?.hasMarkedText() != true else { return event }
      self.onClose?()
      return nil
    }
  }

  public func removeEscapeRouting() {
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    escapeMonitor = nil
  }

  public override func layout() {
    super.layout()
    let inset: CGFloat = 6
    let button: CGFloat = 24
    let gap: CGFloat = 2
    let controlsWidth = button * 3 + gap * 2
    // Below 280 pt put the counts/actions on a second row, retaining a useful
    // editor width in narrow split panes instead of clipping away buttons.
    let stacked = bounds.width < 280
    let fieldWidth = stacked ? bounds.width - inset * 2
      : bounds.width - inset * 3 - controlsWidth - 76
    field.frame = CGRect(x: inset, y: inset, width: max(0, fieldWidth), height: 24)
    let controlsY: CGFloat = stacked ? 32 : inset
    let controlsX = max(inset, bounds.width - inset - controlsWidth)
    previous.frame = CGRect(x: controlsX, y: controlsY, width: button, height: button)
    next.frame = CGRect(x: controlsX + button + gap, y: controlsY, width: button, height: button)
    close.frame = CGRect(x: controlsX + (button + gap) * 2, y: controlsY, width: button, height: button)
    let resultX = stacked ? inset : field.frame.maxX + inset
    result.frame = CGRect(x: resultX, y: controlsY + 4,
      width: max(0, controlsX - resultX - gap), height: 18)
  }

  public static func height(for width: CGFloat) -> CGFloat { width < 280 ? 62 : 36 }

  public func controlTextDidChange(_ notification: Notification) {
    guard !hasMarkedText else { return }
    onQueryChanged?(field.stringValue)
  }

  public func controlTextDidBeginEditing(_ notification: Notification) { onFocusChanged?(true) }
  public func controlTextDidEndEditing(_ notification: Notification) { onFocusChanged?(false) }

  public func control(_ control: NSControl, textView: NSTextView,
                      doCommandBy commandSelector: Selector) -> Bool {
    guard !textView.hasMarkedText() else { return false }
    if commandSelector == #selector(NSResponder.insertNewline(_:))
      || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
      onNavigate?(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      onClose?()
      return true
    }
    return false
  }

  deinit {
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
  }
}

/// Mounted native buttons: state updates preserve focus and system feedback.
@MainActor
private final class BrowserFindButtonHost: NSHostingView<BrowserFindButton> {
  let model: BrowserFindButtonModel

  convenience init(symbol: String, label: String, help: String) {
    self.init(rootView: BrowserFindButton(model: BrowserFindButtonModel(), symbol: symbol,
      label: label, help: help))
  }

  required init(rootView: BrowserFindButton) {
    model = rootView.model
    super.init(rootView: rootView)
    sizingOptions = []
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
private final class BrowserFindButtonModel: ObservableObject {
  @Published var isEnabled = true
  var action: (() -> Void)?
}

private struct BrowserFindButton: View {
  @ObservedObject var model: BrowserFindButtonModel
  let symbol: String
  let label: String
  let help: String

  var body: some View {
    Button { model.action?() } label: {
      Image(systemName: symbol)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.roundedRectangle(radius: BrowserLayout.contentCornerRadius))
    .controlSize(.small)
    .buttonSizing(.flexible)
    .frame(width: 24, height: 24)
    .disabled(!model.isEnabled)
    .help(help)
    .accessibilityLabel(label)
  }
}

@MainActor
private final class BrowserFindSearchField: NSSearchField {
  var onDidFocus: (() -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onDidFocus?() }
    return accepted
  }
}
