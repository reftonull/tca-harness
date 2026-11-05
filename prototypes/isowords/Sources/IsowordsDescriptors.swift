import ComposableArchitecture
import HomeFeature
import SettingsFeature
import StatsFeature
import TCAHarness
import TCAHarnessTCA1

/// The root adapter is generated; upstream features can adopt descriptors without source edits.
@HarnessFeature
@Reducer
struct IsowordsRoot {
  @ObservableState
  struct State {
    var home: Home.State = .init()
    @Presents var plan: ReleasePlan.State?
  }
  enum Action {
    case home(Home.Action)
    case openPlannerButtonTapped
    @HarnessIgnore case plan(PresentationAction<ReleasePlan.Action>)
  }
  var body: some ReducerOf<Self> {
    Scope(state: \.home, action: \.home) { Home() }
    Reduce { state, action in
      if case .openPlannerButtonTapped = action { state.plan = .init() }
      return .none
    }
    .ifLet(\.$plan, action: \.plan) { ReleasePlan() }
  }
}

extension Stats {
  @MainActor static var harnessDescriptor: FeatureDescriptor<State, Action> {
    FeatureDescriptor("Stats")
      .operation("vocabButtonTapped", label: "Open vocabulary", action: .vocabButtonTapped)
      .operation("backButtonTapped", action: .backButtonTapped)
  }
}

extension Settings {
  @MainActor static var harnessDescriptor: FeatureDescriptor<State, Action> {
    FeatureDescriptor("Settings")
      .bindings(\.userSettings, name: "userSettings", numericRanges: ["musicVolume": 0...1, "soundEffectsVolume": 0...1])
      .child("stats", state: \.stats, action: \.stats, descriptor: Stats.harnessDescriptor)
  }
}

extension Home {
  @MainActor static var harnessDescriptor: FeatureDescriptor<State, Action> {
    FeatureDescriptor("Home")
      .operation("cubeButtonTapped", action: .cubeButtonTapped)
      .operation("dailyChallengeButtonTapped", action: .dailyChallengeButtonTapped)
      .operation("howToPlayButtonTapped", action: .howToPlayButtonTapped)
      .operation("leaderboardButtonTapped", action: .leaderboardButtonTapped)
      .operation("multiplayerButtonTapped", action: .multiplayerButtonTapped)
      .operation("settingsButtonTapped", action: .settingsButtonTapped, available: { $0.destination == nil })
      .operation("soloButtonTapped", action: .soloButtonTapped)
      .operation("dismissSettings", action: .destination(.dismiss), available: { $0.destination?.settings != nil })
      .child("settings", state: { $0.destination?.settings },
        action: { .destination(.presented(.settings($0))) }, descriptor: Settings.harnessDescriptor)
  }
}
