import AppFeature
import ComposableArchitecture
import Foundation
import SettingsFeature
import SocialFeature
import TCAHarnessTCA1

/// The upstream Critical Maps `AppFeature` with no UI, served by the same descriptor as the iOS app.
///
/// Usage: `criticalmaps-headless [--port 8790]`. Reads the `TCA_HARNESS_*` run settings and
/// `CRITICALMAPS_HARNESS_LOCATION` from the environment.
@main
@MainActor
enum CriticalMapsHeadless {
  static func main() {
    let arguments = CommandLine.arguments
    let port = arguments.firstIndex(of: "--port").flatMap { arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil } ?? 8790
    // Same order as the app: dependencies are prepared before the store (and any @Shared) exists.
    prepareDependencies { CriticalMapsHarness.prepare(&$0, headless: true) }
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: AppFeature.State()) {
      AppFeature().headlessViewLifecycle().harnessTimeline(timeline)
    }
    let harness = CriticalMapsHarness.attach(to: store, timeline: timeline)
    store.send(.onAppear)  // AppView's `.onAppear`
    Task {
      do { try await harness.runHeadless(port: port) } catch {
        FileHandle.standardError.write(Data("criticalmaps-headless: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
      exit(0)
    }
    RunLoop.main.run()
  }
}

extension Reducer where Self == AppFeature {
  /// Sends what the SwiftUI views send when they appear: `ChatView` and `MastodonFeedView` when their
  /// tab is shown in the social sheet, `SettingsView` when the sheet opens and whenever a pushed
  /// settings page is popped (SwiftUI calls `.onAppear` again then).
  func headlessViewLifecycle() -> some ReducerOf<AppFeature> {
    self
      .onChange(of: { socialTab($0) }) { _, tab in
        Reduce { _, _ in
          switch tab {
          case .chat?: .send(.destination(.presented(.social(.chat(.onAppear)))))
          case .toots?: .send(.destination(.presented(.social(.toots(.onAppear)))))
          case nil: .none
          }
        }
      }
      .onChange(of: { settingsTopVisible($0) }) { _, visible in
        Reduce { _, _ in visible ? .send(.destination(.presented(.settings(.view(.onAppear))))) : .none }
      }
  }
}

private func socialTab(_ state: AppFeature.State) -> SocialFeature.SocialControl? {
  if case let .social(social)? = CriticalMapsHarness.destination(state) { social.socialControl } else { nil }
}

private func settingsTopVisible(_ state: AppFeature.State) -> Bool {
  if case let .settings(settings)? = CriticalMapsHarness.destination(state) {
    CriticalMapsHarness.settingsDestination(settings) == nil
  } else { false }
}
