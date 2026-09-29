//
//  AddressField.swift
//  NativeBrowser
//
//  The native address / search field. Milestone 5 changes only its AppKit
//  appearance; it remains an NSTextField so the field editor continues to own
//  Cmd+L, IME composition, selection, Escape and Return.
//
//  This is an AppKit NSTextField rather than a SwiftUI TextField, for three
//  reasons that matter to this milestone (sections 13, 16 and 18):
//
//    * IME. AppKit's field editor is where input-method composition (marked
//      text, candidate window, commit) is handled exactly like a native macOS
//      text field. Nothing here intercepts key events or touches the field
//      editor's text storage, so Chinese input behaves normally.
//    * Focus. The field can be made first responder from outside SwiftUI, which
//      is what ⌘L needs while Chromium owns the keyboard.
//    * Selection. Select-all works even when the field already owns focus, so
//      the first typed character replaces the current address.
//
//  SwiftUI never pushes text into the field: the model owns the value and the
//  field reports edits back through the coordinator.
//

import AppKit
import SwiftUI

struct AddressField: NSViewRepresentable {
  @ObservedObject var model: AddressFieldModel

  /// Called when the user changes the text (before any submit).
  var onChange: (String) -> Void

  /// Called when the user presses Return.
  var onSubmit: () -> Void

  /// Called when the user presses Escape.
  var onEscape: () -> Void

  /// Called when the field gains or loses keyboard focus.
  var onFocusChange: (Bool) -> Void

  func makeNSView(context: Context) -> NativeBrowserAddressField {
    let field = NativeBrowserAddressField()
    field.placeholderString = AddressFieldModel.placeholder
    field.stringValue = model.compactDisplayText(for: model.committedURL)
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.submitAction(_:))
    field.font = .systemFont(ofSize: 13)
    field.textColor = .labelColor
    field.alignment = .center
    field.isBezeled = false
    field.drawsBackground = false
    field.isEditable = true
    field.isSelectable = true
    field.isEnabled = true
    // The capsule draws one native AppKit focus ring around the whole control,
    // so the text field must not add a second ring around its own bounds.
    field.focusRingType = .none
    field.lineBreakMode = .byTruncatingTail
    field.usesSingleLineMode = true
    // The address bar is an address bar: never rewrite what the user types.
    // Text completion is an NSTextField property; quote/dash/spelling
    // substitution belong to the field editor and are turned off in
    // -configureFieldEditor once AppKit hands the editor over.
    field.isAutomaticTextCompletionEnabled = false
    // The field reports taking the keyboard itself. AppKit does not reliably
    // deliver -controlTextDidBeginEditing for a *programmatic* focus change, so
    // ⌘L would otherwise leave the session believing the page still owns the
    // keyboard - and then creating or switching a tab would steal focus out of
    // the address field. The end of editing still arrives through the delegate
    // (controlTextDidEndEditing), which is when the shared field editor is
    // handed back.
    field.onFocusChange = { [weak coordinator = context.coordinator] focused in
      coordinator?.reportFocusChange(focused)
    }
    context.coordinator.observeFocusRequests(for: field, model: model)
    context.coordinator.observeOutsideClicks(for: field)
    return field
  }

  func updateNSView(_ field: NativeBrowserAddressField, context: Context) {
    context.coordinator.parent = self
    field.alignment = context.coordinator.isFocused ? .left : .center
    // The toolbar is reused when the selected tab changes, so the focus
    // observation has to follow the model it is bound to now.
    context.coordinator.observeFocusRequests(for: field, model: model)
    // Assigning -stringValue while the field editor is active would reset the
    // user's selection and disturb an in-flight IME composition, so the text is
    // only written when it genuinely differs.
    let displayedText = context.coordinator.isFocused
      ? model.editText : model.compactDisplayText(for: model.committedURL)
    field.setDisplayText(displayedText)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  static func dismantleNSView(_ field: NativeBrowserAddressField, coordinator: Coordinator) {
    coordinator.stopObservingFocusRequests()
    coordinator.stopObservingOutsideClicks()
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AddressField
    private var focusObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    /// The model the current observation is registered for. A focus request is
    /// only honoured for the session's own address field.
    private var observedModel: AddressFieldModel?
    private(set) var isFocused = false
    private weak var addressField: NativeBrowserAddressField?
    private let log = AppLog.navigation

    init(parent: AddressField) {
      self.parent = parent
    }

    /// Removes the ⌘L observer.
    ///
    /// Called from -dismantleNSView rather than -deinit: a deinitializer is
    /// nonisolated, so touching the (non-Sendable) observer token there is not
    /// allowed under Swift 6 strict concurrency. SwiftUI always dismantles a
    /// representable's NSView, so this runs.
    func stopObservingFocusRequests() {
      guard let focusObserver else { return }
      NotificationCenter.default.removeObserver(focusObserver)
      self.focusObserver = nil
      self.observedModel = nil
    }

    /// ⌘L arrives as a notification (see BrowserCommandNotifications). The
    /// toolbar has already matched it to a session and forwarded it with that
    /// session's AddressFieldModel, so the observation is registered for that
    /// model only (Milestone 3 section 15). A field can therefore never react to
    /// another tab's ⌘L.
    func observeFocusRequests(for field: NativeBrowserAddressField, model: AddressFieldModel) {
      addressField = field
      if observedModel === model, focusObserver != nil { return }
      stopObservingFocusRequests()
      observedModel = model
      focusObserver = NotificationCenter.default.addObserver(
        forName: .browserAddressFieldShouldFocus,
        object: model,
        queue: .main
      ) { [weak field] _ in
        MainActor.assumeIsolated {
          field?.focusAndSelectAll()
        }
      }
    }

    /// SwiftUI sidebar controls can handle a click without becoming first
    /// responder. End address editing before dispatching an outside click so
    /// the field collapses while the clicked control still receives its event.
    func observeOutsideClicks(for field: NativeBrowserAddressField) {
      guard outsideClickMonitor == nil else { return }
      outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown]
      ) { [weak self, weak field] event in
        guard let self, let field,
              let window = field.window, event.window === window
        else { return event }
        let point = field.convert(event.locationInWindow, from: nil)
        if field.bounds.contains(point) {
          if event.type == .leftMouseDown && !self.isFocused {
            // A first click on text should focus and select the full URL.
            // Consuming this down prevents NSTextField from moving the caret
            // to the clicked character after the selection is made.
            self.reportFocusChange(true)
            field.focusAndSelectAll()
            return nil
          }
          return event
        }
        if self.isFocused {
          window.makeFirstResponder(nil)
        }
        return event
      }
    }

    func stopObservingOutsideClicks() {
      guard let outsideClickMonitor else { return }
      NSEvent.removeMonitor(outsideClickMonitor)
      self.outsideClickMonitor = nil
    }

    /// Return is handled here rather than through -action so that the code that
    /// commits an IME composition and the code that submits are the same code.
    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onEscape()
        return true
      default:
        return false
      }
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.onChange(field.stringValue)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      reportFocusChange(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      reportFocusChange(false)
    }

    /// -target/-action path, used by AppKit versions that send the action
    /// instead of the command selector.
    @objc func submitAction(_ sender: Any?) {
      parent.onSubmit()
    }

    func reportFocusChange(_ focused: Bool) {
      guard isFocused != focused else { return }
      isFocused = focused
      if let addressField {
        let alignment: NSTextAlignment = focused ? .left : .center
        addressField.alignment = alignment
        (addressField.currentEditor() as? NSTextView)?.alignment = alignment
        let text = focused ? parent.model.editText
          : parent.model.compactDisplayText(for: parent.model.committedURL)
        addressField.setDisplayText(text)
      }
      if focused {
        // NSTextField may place the caret later in this same mouse event.
        // Select after that work completes, before the next input event.
        DispatchQueue.main.async { [weak self] in
          guard let self, self.isFocused, !self.parent.model.isEditing else { return }
          self.addressField?.selectAllFromStart()
        }
      }
      let state = focused ? "gained" : "lost"
      log.debug("address field focus \(state, privacy: .public)")
      parent.onFocusChange(focused)
    }
  }
}

/// NSTextField with two additions: it reports first-responder changes (the
/// field editor otherwise hides them) and it can be focused with everything
/// selected, which is what ⌘L must do.
final class NativeBrowserAddressField: NSTextField {
  /// Called on the main thread when this field takes or gives up the keyboard.
  var onFocusChange: (@MainActor (Bool) -> Void)?

  /// Keep the native field editor's text in sync without crossfading an old
  /// URL over the new one during the capsule's width animation.
  func setDisplayText(_ text: String) {
    guard stringValue != text else { return }
    stringValue = text
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      onFocusChange?(true)
      selectAllFromStart()
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      onFocusChange?(false)
    }
    return resigned
  }

  /// SwiftUI's hosting view can leave an embedded AppKit control out of the
  /// window's responder chain after Chromium has owned the keyboard. Re-enter
  /// the normal AppKit path at mouse-down time; AppKit still handles placement
  /// of the caret when the field already has focus.
  override func mouseDown(with event: NSEvent) {
    if let window, !hasKeyboardFocus(in: window) {
      _ = window.makeFirstResponder(self)
    }
    configureFieldEditor()
    super.mouseDown(with: event)
  }

  private func hasKeyboardFocus(in window: NSWindow) -> Bool {
    if window.firstResponder === self { return true }
    guard let editor = currentEditor() else { return false }
    return window.firstResponder === editor
  }

  /// True while the field editor is owned by this field, whether or not it is
  /// currently first responder.
  var isEditingText: Bool {
    currentEditor() != nil
  }

  /// Makes this field first responder with its whole value selected.
  func focusAndSelectAll() {
    guard let window else { return }
    if !hasKeyboardFocus(in: window) {
      window.makeFirstResponder(self)
    }
    configureFieldEditor()
    selectAllFromStart()
  }

  /// Selects the entire address with the active end at the beginning, so the
  /// insertion caret is on the left while the next typed key replaces all.
  func selectAllFromStart() {
    guard let editor = currentEditor() as? NSTextView else { return }
    let end = (editor.string as NSString).length
    editor.setSelectedRange(NSRange(location: end, length: 0))
    editor.moveToBeginningOfDocumentAndModifySelection(nil)
  }

  /// Applies the address-bar text rules to the shared field editor.
  ///
  /// The field editor is a plain NSTextView that AppKit reuses for every text
  /// field in the window, so the substitutions that would rewrite an address
  /// (" -> ", -- -> —, autocorrect) have to be disabled on it rather than on
  /// the NSTextField.
  func configureFieldEditor() {
    guard let editor = currentEditor() as? NSTextView else { return }
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
  }
}
