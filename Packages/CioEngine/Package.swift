// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CioEngine",
  platforms: [.macOS("26.0")],
  products: [.library(name: "CioEngine", targets: ["CioEngine"])],
  dependencies: [.package(path: "../CioModel")],
  targets: [
    .target(name: "CioEngine", dependencies: ["CioModel"],
            linkerSettings: [.linkedLibrary("sqlite3")]),
  ],
  swiftLanguageModes: [.v6]
)
