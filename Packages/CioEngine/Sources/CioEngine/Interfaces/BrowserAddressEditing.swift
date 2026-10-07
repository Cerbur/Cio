import Combine
import Foundation

/// Shares the original object's publisher without introducing mirrored state.
@MainActor
public protocol BrowserEngineObservable: ObservableObject, Sendable
where ObjectWillChangePublisher == ObservableObjectPublisher {}

/// Editing operations consumed by the native address field and its UI.
/// The concrete AddressFieldModel remains in CioUI.
@MainActor
public protocol BrowserAddressEditing: BrowserEngineObservable {
  var committedURL: URL? { get }
  var editText: String { get }
  var isEditing: Bool { get }

  @discardableResult
  func userChangedText(_ text: String) -> Bool

  func endEditing()
  func compactDisplayText(for url: URL?) -> String
}
