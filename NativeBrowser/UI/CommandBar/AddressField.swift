//
//  AddressField.swift
//  NativeBrowser
//
//  The native address / search field.
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
    field.stringValue = model.editText
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.submitAction(_:))
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.bezelStyle = .roundedBezel
    field.lineBreakMode = .byTruncatingTail
    // The address bar is an address bar: never rewrite what the user types.
    // Text completion is an NSTextField property; quote/dash/spelling
    // substitution belong to the field editor and are turned off in
    // -configureFieldEditor once AppKit hands the editor over.
    field.isAutomaticTextCompletionEnabled = false
    context.coordinator.observeFocusRequests(for: field)
    return field
  }

  func updateNSView(_ field: NativeBrowserAddressField, context: Context) {
    context.coordinator.parent = self
    // Assigning -stringValue while the field editor is active would reset the
    // user's selection and disturb an in-flight IME composition, so the text is
    // only written when it genuinely differs.
    if field.stringValue != model.editText {
      field.stringValue = model.editText
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  static func dismantleNSView(_ field: NativeBrowserAddressField, coordinator: Coordinator) {
    coordinator.stopObservingFocusRequests()
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AddressField
    private var focusObserver: NSObjectProtocol?
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
    }

    /// ⌘L arrives as a notification (see BrowserCommandNotifications). The
    /// toolbar has already matched it to this session, so the field only has to
    /// ask its window for first responder status.
    func observeFocusRequests(for field: NativeBrowserAddressField) {
      guard focusObserver == nil else { return }
      focusObserver = NotificationCenter.default.addObserver(
        forName: .browserAddressFieldShouldFocus,
        object: nil,
        queue: .main
      ) { [weak field] _ in
        MainActor.assumeIsolated {
          field?.focusAndSelectAll()
        }
      }
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
  var onFocusChange: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      onFocusChange?(true)
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

  /// True while the field editor is owned by this field, whether or not it is
  /// currently first responder.
  var isEditingText: Bool {
    currentEditor() != nil
  }

  /// Makes this field first responder with its whole value selected.
  func focusAndSelectAll() {
    guard let window else { return }
    if window.firstResponder !== self && window.firstResponder !== currentEditor() {
      window.makeFirstResponder(self)
    }
    configureFieldEditor()
    currentEditor()?.selectAll(nil)
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
