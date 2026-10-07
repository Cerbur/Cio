// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CioModel",
  platforms: [.macOS("26.0")],
  products: [.library(name: "CioModel", targets: ["CioModel"])],
  targets: [
    .target(name: "CioModel"),
    .testTarget(name: "CioModelTests", dependencies: ["CioModel"]),
  ],
  swiftLanguageModes: [.v6]
)
