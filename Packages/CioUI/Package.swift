// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CioUI",
  platforms: [.macOS("26.0")],
  products: [.library(name: "CioUI", targets: ["CioUI"])],
  dependencies: [.package(path: "../CioModel"), .package(path: "../CioEngine")],
  targets: [
    .target(name: "CioUI", dependencies: ["CioModel", "CioEngine"],
      exclude: ["Animation/README.md", "Animation/GLASS_COMPONENT_MOTION.md", "UI/Sidebar/README.md"],
      resources: [.process("UI/Sidebar/SidebarScrollEdge.metal")]),
  ],
  swiftLanguageModes: [.v6]
)
