// swift-tools-version: 6.3
import PackageDescription

// The model-independent core on its own, for runtimes other than TCA's. Apps link `TCAHarness`
// from the root package instead.
let package = Package(
  name: "TCAHarnessCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "TCAHarnessCore", targets: ["TCAHarnessCore"])],
  targets: [.target(name: "TCAHarnessCore")]
)
