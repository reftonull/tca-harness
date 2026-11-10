// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "TCAHarness",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    // What apps link: descriptors, macros, runtime and attachment for TCA stores and @Observable models.
    .library(name: "TCAHarness", targets: ["TCAHarness"]),
    // The model-independent session, protocol and transport, for custom runtimes.
    .library(name: "TCAHarnessCore", targets: ["TCAHarnessCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.13.0"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.5.4"),
    // IssueReporting (issue capture) and, for tests, IssueReportingTestSupport. Same package identity TCA uses.
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.4.0"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"605.0.0"),
  ],
  targets: [
    .target(name: "TCAHarnessCore", path: "TCAHarnessCore/Sources/TCAHarnessCore"),
    .macro(name: "HarnessMacrosPlugin", dependencies: [
      .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      .product(name: "SwiftDiagnostics", package: "swift-syntax"),
      .product(name: "SwiftSyntax", package: "swift-syntax"),
      .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
      .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
    ], path: "TCAHarness/Sources/HarnessMacrosPlugin"),
    .target(name: "TCAHarness", dependencies: [
      "TCAHarnessCore", "HarnessMacrosPlugin",
      .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      .product(name: "CasePaths", package: "swift-case-paths"),
      // IssueReporters.current, for issue capture.
      .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
    ], path: "TCAHarness/Sources/TCAHarness"),
    .testTarget(name: "HarnessMacroTests", dependencies: [
      "HarnessMacrosPlugin", .product(name: "MacroTesting", package: "swift-macro-testing"),
    ], path: "TCAHarness/Tests/HarnessMacroTests"),
    .testTarget(name: "RuntimeTests", dependencies: [
      "TCAHarness", .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
    ], path: "TCAHarness/Tests/RuntimeTests"),
  ]
)
