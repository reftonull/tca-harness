import ComposableArchitecture
import ShelfCore
import SwiftUI
import TCAHarnessTCA1

@main
struct ShelfApp: App {
  @MainActor static let store = Store(initialState: Shelf.State()) {
    Shelf().harnessTimeline()  // inert unless TCA_HARNESS=1
  } withDependencies: {
    ShelfHarness.prepare(&$0)
  }

  /// Retained for the life of the app. Listens only in Debug builds launched with TCA_HARNESS=1.
  @MainActor static let harness = store.harness(descriptor: ShelfHarness.descriptor, verify: ShelfHarness.verify)

  var body: some Scene {
    WindowGroup {
      ShelfView(store: Self.store) {
        // Start listening once the first load has finished, like the headless host, so a run
        // starts from the same state on both rungs.
        do { try Self.harness.startIfEnabled() } catch { print("Shelf harness: \(error)") }
      }
    }
  }
}
