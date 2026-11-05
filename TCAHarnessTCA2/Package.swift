// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

// Separate from the root manifest: TCA 1.13 and the TCA26 beta cannot resolve in one graph.
let package = Package(
  name: "TCAHarnessTCA2",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "TCAHarnessTCA2", targets: ["TCAHarnessTCA2"]),
  ],
  dependencies: [
    .package(path: "../TCAHarness"),
    .package(url: "git@github.com:pointfreeco/TCA26.git", branch: "main"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"605.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.0"),
  ],
  targets: [
    .macro(name: "HarnessMacrosTCA2Plugin", dependencies: [
      .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      .product(name: "SwiftDiagnostics", package: "swift-syntax"),
      .product(name: "SwiftSyntax", package: "swift-syntax"),
      .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
      .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
    ]),
    .target(name: "TCAHarnessTCA2", dependencies: [
      "HarnessMacrosTCA2Plugin",
      .product(name: "TCAHarness", package: "TCAHarness"),
      .product(name: "ComposableArchitecture", package: "TCA26"),
    ]),
    .testTarget(name: "HarnessMacroTCA2Tests", dependencies: [
      "HarnessMacrosTCA2Plugin",
      .product(name: "MacroTesting", package: "swift-macro-testing"),
    ]),
    .testTarget(name: "TCAHarnessTCA2Tests", dependencies: ["TCAHarnessTCA2"]),
  ]
)
