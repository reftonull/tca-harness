// swift-tools-version: 6.2
import PackageDescription

// Runs the upstream Critical Maps AppFeature with no UI, behind the same harness descriptor as the
// iOS app (CriticalMapsHarness.swift, symlinked here). Upstream features import UIKit, so this
// builds for Mac Catalyst: a plain macOS process that links UIKit but never starts an app or window.
// The harness listener is compiled only with DEBUG, so build the debug configuration:
//
//   swift build --triple arm64-apple-ios-macabi
let package = Package(
  name: "criticalmaps-headless",
  platforms: [.macOS(.v14), .macCatalyst(.v17), .iOS(.v17)],
  dependencies: [
    // Prepared by ../setup.py (pinned revision, Catalyst platform added to the manifest).
    .package(path: "../.upstream/CriticalMapsKit"),
    .package(path: "../../.."),
    // Upstream's location client, for the fixed-coordinate fake (pinned by Package.resolved).
    .package(url: "https://github.com/mltbnz/composable-core-location", branch: "tca-migration"),
  ],
  targets: [
    .executableTarget(
      name: "criticalmaps-headless",
      dependencies: [
        .product(name: "ApiClient", package: "CriticalMapsKit"),
        .product(name: "AppFeature", package: "CriticalMapsKit"),
        .product(name: "ChatFeature", package: "CriticalMapsKit"),
        .product(name: "FeedbackGeneratorClient", package: "CriticalMapsKit"),
        .product(name: "MapFeature", package: "CriticalMapsKit"),
        .product(name: "MastodonFeedFeature", package: "CriticalMapsKit"),
        .product(name: "NextRideFeature", package: "CriticalMapsKit"),
        .product(name: "SettingsFeature", package: "CriticalMapsKit"),
        .product(name: "SharedKeys", package: "CriticalMapsKit"),
        .product(name: "SharedModels", package: "CriticalMapsKit"),
        .product(name: "SocialFeature", package: "CriticalMapsKit"),
        .product(name: "UIApplicationClient", package: "CriticalMapsKit"),
        .product(name: "ComposableCoreLocation", package: "composable-core-location"),
        .product(name: "TCAHarnessTCA1", package: "tca-harness"),
      ]
    ),
  ],
  swiftLanguageModes: [.v5]
)
