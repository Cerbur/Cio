import AppKit
import CioEngine
import Foundation

/// The original App-owned container. nativeView must return that same NSView.
@MainActor
public protocol BrowserNativeSurface: AnyObject {
  var nativeView: NSView { get }
  var browserSession: (any BrowserSessionProtocol)? { get }

  /// Forward to the original container method, including its delegate callback.
  /// Merely setting NSView.isHidden does not preserve the original behavior.
  func setSurfaceVisible(_ visible: Bool)
}

/// A transfer value containing original references, not copied browser state.
/// App creates attachments from its existing container/session registry.
@MainActor
public struct BrowserSurfaceAttachment {
  public let surface: any BrowserNativeSurface

  public var nativeView: NSView { surface.nativeView }

  public init(
    surface: any BrowserNativeSurface
  ) {
    self.surface = surface
  }
}

/// The original Runtime panel cases and raw-value identity, now owned by CioUI.
public enum BrowserInternalPanel: String, Identifiable, Sendable {
  case history
  case downloads

  public var id: String { rawValue }
}
