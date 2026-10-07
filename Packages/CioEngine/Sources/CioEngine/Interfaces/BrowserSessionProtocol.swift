import Combine
import Foundation
import CioModel

/// Access to the original App-owned session, including its original publishers.
/// SiteInformation belongs to Engine; SearchEngine belongs to CioModel.
@MainActor
public protocol BrowserSessionProtocol: BrowserEngineObservable {
  /// Runtime identity; distinct from the workspace tab identity.
  var id: UUID { get }
  var tabID: UUID { get }

  var title: String { get }
  var url: URL? { get }
  var faviconURLs: [URL] { get }
  var isLoading: Bool { get }
  var canGoBack: Bool { get }
  var canGoForward: Bool { get }
  var rendererCrashed: Bool { get }
  var hasFinishedFirstLoad: Bool { get }
  var siteInformation: SiteInformation { get }

  /// Projects the session's existing addressField without replacing it.
  var engineAddressField: any BrowserAddressEditing { get }

  /// Native focus queries used by the existing workspace selection policy.
  var ownsPageKeyboard: Bool { get }
  var isEditingAddressField: Bool { get }

  /// Each publisher directly erases the corresponding original @Published stream.
  var canGoBackPublisher: AnyPublisher<Bool, Never> { get }
  var canGoForwardPublisher: AnyPublisher<Bool, Never> { get }
  var urlPublisher: AnyPublisher<URL?, Never> { get }
  var isLoadingPublisher: AnyPublisher<Bool, Never> { get }
  var lastErrorCodePublisher: AnyPublisher<Int?, Never> { get }
  var rendererCrashedPublisher: AnyPublisher<Bool, Never> { get }
  var hasFinishedFirstLoadPublisher: AnyPublisher<Bool, Never> { get }

  func load(_ url: URL)
  func reload()
  func reloadOrStop()
  func goBack()
  func goForward()
  func focusPage()
  func blur()
  func addressFieldFocusChanged(_ focused: Bool)
  func submitAddressField(searchEngine: any SearchEngine)
  func cancelAddressEditing()
  func releaseFocusBeforeTabRemoval()
}

public extension BrowserSessionProtocol {
  /// Preserve the existing default search engine without a default argument
  /// in the protocol requirement.
  func submitAddressField() {
    submitAddressField(searchEngine: GoogleSearchEngine())
  }
}
