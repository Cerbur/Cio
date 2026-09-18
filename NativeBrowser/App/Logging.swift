//
//  Logging.swift
//  NativeBrowser
//
//  Unified logging categories (ARCHITECTURE.md section 35). Lifecycle
//  sensitive paths log through these; print() is not used for observability.
//

import Foundation
import OSLog

enum AppLog {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.NativeBrowser"

  /// Application lifecycle: launch, activation, termination.
  static let app = Logger(subsystem: subsystem, category: "app")

  /// CEF initialization, shutdown, message pump and bridge failures.
  static let cef = Logger(subsystem: subsystem, category: "cef")

  /// Browser creation and destruction.
  static let browser = Logger(subsystem: subsystem, category: "browser")

  /// Navigation events.
  static let navigation = Logger(subsystem: subsystem, category: "navigation")

  /// Session / workspace state.
  static let session = Logger(subsystem: subsystem, category: "session")
}
