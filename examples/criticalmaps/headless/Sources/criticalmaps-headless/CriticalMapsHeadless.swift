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
  /// Sends what the SwiftUI views send when they appear and disappear: `ChatView` and
  /// `MastodonFeedView` when their tab is shown in the social sheet, `SettingsView` when the sheet
  /// opens and whenever a pushed settings page is popped (SwiftUI calls `.onAppear` again then), and
  /// each sheet's `onDismiss` once it has gone away, however it was closed (a button, a swipe, or
  /// another sheet taking its place). The app sends `onDismiss` when the dismissal animation ends;
  /// here it follows the closing action at once, so the late-dismissal race (finding 6) stays a
  /// UI-rung finding.
  func headlessViewLifecycle() -> some ReducerOf<AppFeature> {
    self
      .onChange(of: { Sheet($0) }) { closed, _ in
        Reduce { _, _ in closed.map { .send($0.onDismiss) } ?? .none }
      }
      // MapFeatureView's share sheet: `onDismiss: { store.send(.showShareSheet(false)) }`.
      .onChange(of: \.mapFeatureState.presentShareSheet) { wasShown, isShown in
        Reduce { _, _ in wasShown && !isShown ? .send(.map(.showShareSheet(false))) : .none }
      }
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

/// The sheets `AppView` and `AppNavigationView` present, each with the action its `onDismiss` sends.
private enum Sheet: Equatable {
  case whatsNew, social, settings, rides

  init?(_ state: AppFeature.State) {
    switch CriticalMapsHarness.destination(state) {
    case .whatsNew?: self = .whatsNew
    case .social?: self = .social
    case .settings?: self = .settings
    case .rideEvents?: self = .rides
    case nil: return nil
    }
  }

  var onDismiss: AppFeature.Action {
    switch self {
    case .whatsNew: .whatsNewDismissed
    case .social, .settings: .dismissDestination
    case .rides: .dismissEventList
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
