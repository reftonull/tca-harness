// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "TCAHarness",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "TCAHarness", targets: ["TCAHarness"]),
    .library(name: "TCAHarnessTCA1", targets: ["TCAHarnessTCA1"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.13.0"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.5.4"),
    // Test-only: IssueReportingTestSupport. Same package identity TCA 1 uses.
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.4.0"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"605.0.0"),
  ],
  targets: [
    .target(name: "TCAHarness", path: "TCAHarness/Sources/TCAHarness"),
    .macro(name: "HarnessMacrosPlugin", dependencies: [
      .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      .product(name: "SwiftDiagnostics", package: "swift-syntax"),
      .product(name: "SwiftSyntax", package: "swift-syntax"),
      .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
      .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
    ], path: "TCAHarnessTCA1/Sources/HarnessMacrosPlugin"),
    .target(name: "TCAHarnessTCA1", dependencies: [
      "TCAHarness", "HarnessMacrosPlugin",
      .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      .product(name: "CasePaths", package: "swift-case-paths"),
    ], path: "TCAHarnessTCA1/Sources/TCAHarnessTCA1"),
    .testTarget(name: "HarnessMacroTests", dependencies: [
      "HarnessMacrosPlugin", .product(name: "MacroTesting", package: "swift-macro-testing"),
    ], path: "TCAHarnessTCA1/Tests/HarnessMacroTests"),
    .testTarget(name: "RuntimeTests", dependencies: [
      "TCAHarnessTCA1", .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
    ], path: "TCAHarnessTCA1/Tests/RuntimeTests"),
  ]
)
