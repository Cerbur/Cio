import CioEngine
import Foundation

/// Retrieval follows userInput; candidate previews only change the field's display.
struct SpotlightInputState {
  private(set) var userInput = ""
  private(set) var text = ""
  private(set) var selection: NSRange?
  private(set) var previewID: String?
  private(set) var revision = 0
  private(set) var isComposing = false
  private var allowsAutomaticCompletion = true

  mutating func edit(_ value: String, isComposing: Bool, allowsAutomaticCompletion: Bool) {
    userInput = value
    text = value
    selection = nil
    previewID = nil
    self.isComposing = isComposing
    self.allowsAutomaticCompletion = allowsAutomaticCompletion
    revision += 1
  }

  mutating func preview(_ suggestion: SpotlightSuggestion?, explicit: Bool) {
    guard !isComposing else { return }
    // A provider can add rows without changing the selected candidate. Preserve
    // the caret if the user has already accepted or repositioned its completion.
    if let suggestion, previewID == suggestion.id { return }

    var value = userInput
    var range = NSRange(location: (value as NSString).length, length: 0)
    var candidateID: String?
    if let suggestion, suggestion.kind != .input {
      let completion = completionText(for: suggestion.mode)
      let prefix = (completion as NSString).range(
        of: userInput, options: [.anchored, .caseInsensitive, .diacriticInsensitive])
      let end = (completion as NSString).length
      let extendsInput = !userInput.isEmpty && prefix.location == 0 && NSMaxRange(prefix) < end
      if explicit || (allowsAutomaticCompletion && extendsInput) {
        value = completion
        range = extendsInput
          ? NSRange(location: NSMaxRange(prefix), length: end - NSMaxRange(prefix))
          : NSRange(location: end, length: 0)
        candidateID = suggestion.id
      }
    }
    guard text != value || previewID != candidateID else { return }
    text = value
    selection = range
    previewID = candidateID
    revision += 1
  }

  mutating func acceptCompletion() {
    guard let selection, selection.length > 0 else { return }
    self.selection = NSRange(location: (text as NSString).length, length: 0)
    revision += 1
  }

  private func completionText(for mode: SpotlightMode) -> String {
    switch mode {
    case .googleSearch(let query): return query
    case .website(let url):
      var value = url.absoluteString
      if let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
         !userInput.lowercased().hasPrefix("\(scheme.lowercased())://") {
        value.removeFirst(scheme.count + 3)
      }
      // Domain rows omit the conventional www label. Match their display so
      // typing "bil" can complete to "bilibili.com" even when history uses www.
      if let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
         !userInput.lowercased().hasPrefix("www."),
         !userInput.lowercased().hasPrefix("\(scheme.lowercased())://www.") {
        let prefix = value.hasPrefix("\(scheme)://") ? "\(scheme)://" : ""
        value = value.replacingOccurrences(
          of: "\(prefix)www.", with: prefix, options: [.anchored, .caseInsensitive])
      }
      if url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
         value.hasSuffix("/") {
        value.removeLast()
      }
      return value
    }
  }
}
