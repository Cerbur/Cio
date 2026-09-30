import Combine
import Foundation

/// Address-bar request and selection state, independent of the Spotlight panel.
@MainActor
final class AddressAutocompleteModel: ObservableObject {
  nonisolated static let rowLimit = 5
  @Published private(set) var input = SpotlightInputState()
  @Published private(set) var suggestions: [SpotlightSuggestion] = []
  @Published private(set) var selectedIndex = 0
  @Published private(set) var isActive = false
  private var selectedID: String?
  private let service: NavigationAutocompleteService
  private var observation: AnyCancellable?

  init(history: HistoryService, searchProvider: SearchSuggestionProvider = .init()) {
    service = NavigationAutocompleteService(history: history, searchProvider: searchProvider)
    observation = service.$snapshot.sink { [weak self] snapshot in
      self?.apply(snapshot)
    }
  }

  func begin(_ text: String) {
    isActive = true
    edit(text, isComposing: false, allowsCompletion: false)
  }

  func end() {
    isActive = false
    service.cancel()
    suggestions = []
    selectedID = nil
    selectedIndex = 0
  }

  func edit(_ text: String, isComposing: Bool, allowsCompletion: Bool) {
    input.edit(text, isComposing: isComposing, allowsAutomaticCompletion: allowsCompletion)
    selectedID = nil
    selectedIndex = 0
    // Only genuine edits trigger retrieval. Candidate previews never enter here.
    if isComposing {
      service.cancel()
      suggestions = []
    } else {
      service.update(text)
      apply(service.snapshot)
    }
  }

  func acceptCompletion() { input.acceptCompletion() }

  func move(_ direction: Int) {
    guard !suggestions.isEmpty else { return }
    select((selectedIndex + direction + suggestions.count) % suggestions.count)
  }

  func select(_ index: Int) {
    guard !input.isComposing, suggestions.indices.contains(index) else { return }
    selectedIndex = index
    selectedID = suggestions[index].id
    input.preview(suggestions[index], explicit: true)
  }

  var selectedMode: SpotlightMode? {
    guard isActive, !input.isComposing, suggestions.indices.contains(selectedIndex) else { return nil }
    return suggestions[selectedIndex].mode
  }

  private func apply(_ snapshot: NavigationAutocompleteSnapshot) {
    guard isActive, !input.isComposing,
          snapshot.input == input.userInput.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
    suggestions = Array(SpotlightAutocompleteService.merge(
      domain: snapshot.domain.map(SpotlightSuggestion.init),
      input: snapshot.inputSuggestion.map(SpotlightSuggestion.init),
      history: snapshot.history.map(SpotlightSuggestion.init),
      online: snapshot.online.map(SpotlightSuggestion.init)).prefix(Self.rowLimit))
    if let selectedID, let index = suggestions.firstIndex(where: { $0.id == selectedID }) {
      selectedIndex = index
    } else {
      selectedID = nil
      selectedIndex = 0
    }
    input.preview(suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil,
                  explicit: selectedID != nil)
  }
}
