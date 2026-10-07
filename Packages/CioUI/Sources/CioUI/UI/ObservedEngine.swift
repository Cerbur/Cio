import Combine
import CioEngine
import SwiftUI

/// This box has no actor isolation and no independently published state.
/// Its stored publisher is the original object's publisher, not a relay.
private nonisolated final class EngineObservationBox<Value>: ObservableObject {
  let value: Value
  let objectWillChange: ObservableObjectPublisher

  init(value: Value, publisher: ObservableObjectPublisher) {
    self.value = value
    self.objectWillChange = publisher
  }
}

/// Observes an Engine protocol existential while returning the original object.
/// Value is intentionally unconstrained: existential types do not need to
/// satisfy an ObservableObject generic constraint themselves.
@MainActor
@propertyWrapper
public struct ObservedEngine<Value>: DynamicProperty {
  @ObservedObject private var box: EngineObservationBox<Value>

  public var wrappedValue: Value { box.value }

  public init(wrappedValue: Value) {
    guard let original = wrappedValue as? any BrowserEngineObservable else {
      preconditionFailure("ObservedEngine requires a BrowserEngineObservable object")
    }

    _box = ObservedObject(wrappedValue: EngineObservationBox(
      value: wrappedValue,
      publisher: original.objectWillChange
    ))
  }
}
