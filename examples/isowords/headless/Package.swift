// swift-tools-version: 6.0
import Foundation
import PackageDescription

// A path dependency's identity is its directory name: `tca-harness` in a normal clone, something
// else in a git worktree or a renamed checkout.
let harness = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("../../..").standardizedFileURL.resolvingSymlinksInPath().lastPathComponent

// Runs the upstream isowords AppReducer with no UI, behind the same harness descriptor as the
// iOS example. Upstream feature modules import UIKit, so this builds for Mac Catalyst: a plain
// macOS process that links UIKit but never starts an app, window or simulator. The harness
// listener is compiled only with DEBUG: build debug, or pass `-Xswiftc -DDEBUG` with `-c release`.
let package = Package(
  name: "isowords-headless",
  platforms: [.macOS(.v14), .macCatalyst(.v17), .iOS(.v17)],
  dependencies: [
    // Prepared by ../setup.py; TCA is pinned to 1.26.2 there (../client-pins.json).
    .package(path: "../.upstream"),
    .package(path: "../../.."),
  ],
  targets: [
    .executableTarget(
      name: "isowords-headless",
      dependencies: [
        .product(name: "AppFeature", package: ".upstream"),
        .product(name: "DictionarySqliteClient", package: ".upstream"),
        .product(name: "GameCore", package: ".upstream"),
        .product(name: "HomeFeature", package: ".upstream"),
        .product(name: "SettingsFeature", package: ".upstream"),
        .product(name: "SharedModels", package: ".upstream"),
        .product(name: "SoloFeature", package: ".upstream"),
        .product(name: "TCAHarnessTCA1", package: harness),
      ]
    ),
  ],
  swiftLanguageModes: [.v5]
)
