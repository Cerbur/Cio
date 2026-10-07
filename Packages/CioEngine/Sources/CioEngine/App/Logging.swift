//
//  Logging.swift
//  Cio
//
//  Unified logging categories (ARCHITECTURE.md section 35). Lifecycle
//  sensitive paths log through these; print() is not used for observability.
//

import Foundation
import OSLog

public enum AppLog {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.cerbur.Cio"

  /// Application lifecycle: launch, activation, termination.
  public static let app = Logger(subsystem: subsystem, category: "app")

  /// CEF initialization, shutdown, message pump and bridge failures.
  public static let cef = Logger(subsystem: subsystem, category: "cef")

  /// Browser creation and destruction.
  public static let browser = Logger(subsystem: subsystem, category: "browser")

  /// Navigation events.
  public static let navigation = Logger(subsystem: subsystem, category: "navigation")

  /// Session / workspace state.
  public static let session = Logger(subsystem: subsystem, category: "session")
}
