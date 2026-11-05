import ComposableArchitecture
import DecisionDomain
import DecisionHarness
import Foundation
import SwiftUI

@main
struct DecisionsTCAApp: App {
  static let store = Store(initialState: TaskList.State()) { TaskList() }

  #if DEBUG && targetEnvironment(simulator)
  // Macro-generated descriptors (`@HarnessFeature`) attached to the existing store.
  static let harness = TaskHarness.attach(to: store)
  static let enabled = ProcessInfo.processInfo.environment["TCA_HARNESS"] == "1"
  #endif

  private var harnessStatus: String? {
    #if DEBUG && targetEnvironment(simulator)
    Self.enabled ? "\(Self.harness.server.status) · \(Self.harness.server.requestCount) calls" : nil
    #else
    nil
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView(store: Self.store, harnessStatus: harnessStatus)
        #if DEBUG && targetEnvironment(simulator)
        .task {
          do { try Self.harness.startIfEnabled() }
          catch { print("Harness could not start: \(error.localizedDescription)") }
        }
        #endif
    }
  }
}
