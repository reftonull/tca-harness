// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "TCAHarness",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "TCAHarness", targets: ["TCAHarness"])],
  targets: [.target(name: "TCAHarness")]
)
