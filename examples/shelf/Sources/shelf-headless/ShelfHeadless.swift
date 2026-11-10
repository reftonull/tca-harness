import ComposableArchitecture
import Foundation
import ShelfCore
import TCAHarnessTCA1

/// Shelf's reducers with no UI, served on the harness port. ShelfCore imports neither SwiftUI nor
/// UIKit, so this is a plain macOS executable.
///
/// Usage: `shelf-headless [--port 8790]`. Reads `SHELF_API`, `SHELF_BUGS` and the `TCA_HARNESS_*`
/// run settings (network mode, cassettes, seed) from the environment.
@main
@MainActor
enum ShelfHeadless {
  static func main() async {
    let arguments = CommandLine.arguments
    let port = arguments.firstIndex(of: "--port").flatMap {
      arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil
    } ?? 8790
    // Record for `tca devtools` (and the issue oracle's `action`) without requiring TCA_HARNESS=1.
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: Shelf.State()) {
      Shelf().harnessTimeline(timeline)
    } withDependencies: {
      ShelfHarness.prepare(&$0)
    }
    let harness = store.harness(descriptor: ShelfHarness.descriptor, verify: ShelfHarness.verify, timeline: timeline)
    // What ShelfView sends when it appears. Deliberately not `.markShelfSeen` (its `.onAppear`):
    // that's the view-only logic the `view-only-seen` bug relies on, found by `tca diff`.
    // Listen once the first load has finished, as the app does, so every run starts from the
    // same state.
    await store.send(.task).finish()
    do {
      try await harness.runHeadless(port: port)
    } catch {
      FileHandle.standardError.write(Data("shelf-headless: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
