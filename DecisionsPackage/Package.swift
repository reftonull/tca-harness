// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "DecisionsPackage",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "DecisionDomain", targets: ["DecisionDomain"]),
    .library(name: "DecisionHarness", targets: ["DecisionHarness"]),
  ],
  dependencies: [
    .package(url: "git@github.com:pointfreeco/TCA26.git", branch: "main"),
    .package(path: "../TCAHarnessTCA2"),
  ],
  targets: [
    .target(name: "DecisionDomain", dependencies: [
      .product(name: "ComposableArchitecture", package: "TCA26"),
      .product(name: "TCAHarnessTCA2", package: "TCAHarnessTCA2"),
    ]),
    .target(name: "DecisionHarness", dependencies: [
      "DecisionDomain",
      .product(name: "TCAHarnessTCA2", package: "TCAHarnessTCA2"),
      .product(name: "ComposableArchitecture", package: "TCA26"),
    ]),
  ]
)
