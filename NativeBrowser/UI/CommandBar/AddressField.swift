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
  /// The toolbar controller owns the presentation state across tab changes.
  var isFocused: Bool
  /// Local AppKit monitors bypass SwiftUI's allowsHitTesting. Read the owning
  /// toolbar's current visibility even while its native editor stays mounted.
  var acceptsInteraction: () -> Bool

  /// Called when the user changes the text (before any submit).
  var completion: SpotlightInputState? = nil
  var dropdownHeight: CGFloat = 0
  var onChange: (String, Bool, Bool) -> Void
  var onAcceptCompletion: () -> Void = {}
  var onMove: (Int) -> Void = { _ in }

  /// Called when the user presses Return.
  var onSubmit: () -> Void

  /// Called when the user presses Escape.
  var onEscape: () -> Void

  /// Routed through the toolbar so both reload controls use one command path.
  var onReloadOrStop: () -> Void

  /// The favicon is a peer of the reload control above the native field.
  var onSiteInformationToggle: () -> Void

  /// Called when the field gains or loses keyboard focus.
  var onFocusChange: (Bool) -> Void

  func makeNSView(context: Context) -> NativeBrowserAddressField {
    let field = NativeBrowserAddressField()
    // Keep .URL explicit before focus, even when this field accepts search text.
    // A nil content type enables AppKit's password/one-time-code AutoFill
    // heuristics, independently of isAutomaticTextCompletionEnabled. Keep this
    // aligned with SpotlightInputField; its comment records the captured popup
    // call path and the cold-launch check needed to catch a few-frame regression.
    field.contentType = .URL
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
    // In the shell-owned toolbar, AppKit must not choose the address as the
    // window's initial editor. Capsule clicks and Cmd+L enable it explicitly.
    field.refusesFirstResponder = true
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
    // the address field. End-of-editing usually arrives through the delegate;
    // the outside-click monitor also reports it when AppKit keeps the shared
    // field editor attached.
    field.onFocusChange = { [weak coordinator = context.coordinator] focused in
      coordinator?.reportFocusChange(focused)
    }
    context.coordinator.observeFocusRequests(for: field, model: model)
    context.coordinator.observeOutsideClicks(for: field)
    return field
  }

  func updateNSView(_ field: NativeBrowserAddressField, context: Context) {
    context.coordinator.parent = self
    context.coordinator.syncFocusFromToolbar(isFocused)
    field.alignment = isFocused ? .left : .center
    // The toolbar is reused when the selected tab changes, so the focus
    // observation has to follow the model it is bound to now.
    context.coordinator.observeFocusRequests(for: field, model: model)
    // Assigning -stringValue while the field editor is active would reset the
    // user's selection and disturb an in-flight IME composition, so the text is
    // only written when it genuinely differs.
    let displayedText = isFocused
      ? (completion?.text ?? model.editText) : model.compactDisplayText(for: model.committedURL)
    if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.setDisplayText(displayedText)
      context.coordinator.applyCompletion(to: field)
    }
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
    private var lastAppliedRevision = -1
    private var isApplyingPreview = false
    private var isDeleting = false

    func applyCompletion(to field: NativeBrowserAddressField) {
      guard parent.isFocused, let input = parent.completion,
            lastAppliedRevision != input.revision else { return }
      let editor = field.currentEditor() as? NSTextView
      guard editor?.hasMarkedText() != true else { return }
      lastAppliedRevision = input.revision
      isApplyingPreview = true
      defer { isApplyingPreview = false }
      field.setDisplayText(input.text)
      if let range = input.selection {
        editor?.setSelectedRange(range)
        editor?.scrollRangeToVisible(range)
      }
    }

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
      ) { [weak self, weak field, weak model] _ in
        MainActor.assumeIsolated {
          // Capsule taps finish in SwiftUI after this notification returns.
          // Focus on the next turn so the hosting view cannot reclaim the
          // responder and discard the field editor's selection.
          DispatchQueue.main.async { [weak self, weak field, weak model] in
            guard let self, let model, self.observedModel === model,
                  self.parent.acceptsInteraction() else { return }
            self.reportFocusChange(true)
            field?.focusAndSelectAll()
          }
        }
      }
    }

    /// End editing on any click outside the capsule, including clicks on
    /// controls that do not become first responder themselves.
    func observeOutsideClicks(for field: NativeBrowserAddressField) {
      guard outsideClickMonitor == nil else { return }
      outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown]
      ) { [weak self, weak field] event in
        guard let self, self.parent.acceptsInteraction(),
              let field, let window = field.window
        else { return event }
        let fieldRect = field.convert(field.bounds, to: nil)
        // The expanded input starts at the candidate text column. Include its
        // wider leading inset so icon and list-edge clicks stay inside the panel.
        let leadingInset = self.parent.dropdownHeight > 0
          ? AddressCapsuleLayout.suggestionTextInset : AddressCapsuleLayout.endControlWidth
        let capsuleRect = NSRect(
          x: fieldRect.minX - leadingInset,
          y: fieldRect.midY - AddressCapsuleLayout.height / 2,
          width: fieldRect.width + leadingInset + AddressCapsuleLayout.endControlWidth,
          height: AddressCapsuleLayout.height)
        if event.window === window,
           capsuleRect.contains(event.locationInWindow) {
          if event.type == .leftMouseDown {
            switch AddressCapsuleInteraction.target(
              at: event.locationInWindow, in: capsuleRect,
              hasSuggestions: self.parent.dropdownHeight > 0
            ) {
            case .siteInformation:
              self.parent.onSiteInformationToggle()
              return nil
            case .reloadOrStop:
              self.parent.onReloadOrStop()
              if self.isFocused { field.focusAndSelectAll() }
              return nil
            case .address:
              break
            }
            if !fieldRect.contains(event.locationInWindow) || !self.isFocused {
              // Handle the full capsule before SwiftUI's host can take the
              // responder. Text clicks while already editing retain caret
              // placement; first clicks select the full committed address.
              self.reportFocusChange(true)
              field.focusAndSelectAll()
              return nil
            }
          }
          return event
        }
        if self.isFocused, event.window === window {
          var dropdownRect = capsuleRect
          dropdownRect.origin.y -= self.parent.dropdownHeight
          dropdownRect.size.height = self.parent.dropdownHeight
          if dropdownRect.contains(event.locationInWindow) { return event }
        }
        if self.isFocused {
          window.makeFirstResponder(nil)
          // Some click targets never take first responder, so AppKit may not
          // send an end-editing callback on its own.
          self.reportFocusChange(false)
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
      if textView.hasMarkedText() { return false }
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onEscape()
        // The page may take first responder without AppKit sending this
        // field's end-editing callback. Keep the toolbar state in sync.
        reportFocusChange(false)
        return true
      case #selector(NSResponder.moveUp(_:)):
        parent.onMove(-1)
        return true
      case #selector(NSResponder.moveDown(_:)):
        parent.onMove(1)
        return true
      case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveRight(_:)),
           #selector(NSResponder.moveToEndOfLine(_:)):
        guard let range = parent.completion?.selection, range.length > 0,
              textView.selectedRange() == range else { return false }
        parent.onAcceptCompletion()
        return true
      case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
        isDeleting = true
        return false
      default:
        return false
      }
    }

    func controlTextDidChange(_ notification: Notification) {
      guard !isApplyingPreview, let field = notification.object as? NSTextField else { return }
      let editor = field.currentEditor() as? NSTextView
      let isComposing = editor?.hasMarkedText() == true
      let atEnd = editor?.selectedRange() == NSRange(location: (field.stringValue as NSString).length, length: 0)
      let allowsCompletion = !isComposing && !isDeleting && atEnd
      isDeleting = false
      parent.onChange(field.stringValue, isComposing, allowsCompletion)
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

    /// Selection changes arrive from the toolbar even when AppKit does not
    /// report an end-editing callback for the shared field editor.
    func syncFocusFromToolbar(_ focused: Bool) {
      isFocused = focused
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
    refusesFirstResponder = false
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
    refusesFirstResponder = false
    guard let window else { return }
    if !hasKeyboardFocus(in: window) {
      _ = window.makeFirstResponder(self)
    }
    // Becoming first responder does not necessarily install NSTextField's
    // shared field editor. Start editing before selecting, so capsule clicks
    // and ⌘L leave the address ready for the next keystroke.
    if currentEditor() == nil { selectText(nil) }
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
