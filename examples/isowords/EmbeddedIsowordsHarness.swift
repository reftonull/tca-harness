import AppFeature
import ComposableArchitecture
import GameCore
import HomeFeature
import SharedModels
import SoloFeature
import SettingsFeature
import TCAHarnessTCA1
import UIKit

/// App-specific capabilities for the original upstream root store.
@MainActor
enum EmbeddedIsowordsHarness {
  static func attach(to store: StoreOf<AppReducer>) -> StoreHarness<AppReducer.State, AppReducer.Action> {
    let settings = FeatureDescriptor<Settings.State, Settings.Action>("Settings", observation: Self.settingsSnapshot)
      .operation("darkMode", label: "Set color scheme to dark", action: .binding(.set(\.userSettings.colorScheme, .dark)),
        available: { $0.userSettings.colorScheme != .dark })
      .operation("reduceAnimation", label: "Enable reduced animation", action: .binding(.set(\.userSettings.enableReducedAnimation, true)),
        available: { !$0.userSettings.enableReducedAnimation })
      .operation("disableHaptics", label: "Disable haptics", action: .binding(.set(\.userSettings.enableHaptics, false)),
        available: { $0.userSettings.enableHaptics })
      .operation("musicVolume", label: "Set music volume from 0 (silent) to 1 (full volume)", arguments: VolumeInput.self,
        action: { .binding(.set(\.userSettings.musicVolume, Float($0.value))) })
    let solo = FeatureDescriptor<Solo.State, Solo.Action>("Solo")
      .operation("startUnlimited", label: "Start an unlimited solo game", action: .gameButtonTapped(.unlimited))
      .operation("startTimed", label: "Start a timed solo game", action: .gameButtonTapped(.timed))
    let home = FeatureDescriptor<Home.State, Home.Action>("Home")
      .operation("openSolo", label: "Open Solo game modes", action: .soloButtonTapped, available: { $0.destination == nil })
      .operation("openSettings", label: "Open Settings", action: .settingsButtonTapped, available: { $0.destination == nil })
      .operation("dismiss", label: "Close the current Home sheet and return Home", action: .destination(.dismiss), available: { $0.destination != nil })
      .child("settings", state: { $0.destination?.settings }, action: { .destination(.presented(.settings($0))) }, descriptor: settings)
      .child("solo", state: { $0.destination?.solo }, action: { .destination(.presented(.solo($0))) }, descriptor: solo)
    var game = FeatureDescriptor<Game.State, Game.Action>("Game", observation: Self.gameSnapshot)
      .operation("release", label: "Release the selected cube face", action: .tap(.ended, nil), available: { $0.optimisticallySelectedFace != nil })
      .operation("clear", label: "Clear selected word", action: .cancelButtonTapped, available: { !$0.selectedWord.isEmpty })
      .operation("submit", label: "Submit the selected valid word", action: .submitButtonTapped(reaction: nil),
        available: { $0.selectedWordIsValid && !$0.selectedWordHasAlreadyBeenPlayed && $0.optimisticallySelectedFace == nil })
      .operation("openMenu", label: "Open the game menu", action: .menuButtonTapped, available: { $0.destination == nil })
      .operation("exitToHome", label: "Return to Home, keeping the unlimited game for later", action: .destination(.presented(.bottomMenu(.exitButtonTapped))),
        available: { $0.destination?.bottomMenu != nil && $0.isResumable })
      .operation("openSettings", label: "Open Settings from the game menu", action: .destination(.presented(.bottomMenu(.settingsButtonTapped))),
        available: { $0.destination?.bottomMenu != nil })
      .operation("dismiss", label: "Close the game menu or Settings and return to the board", action: .destination(.dismiss),
        available: { $0.destination?.bottomMenu != nil || $0.destination?.settings != nil })
      .child("settings", state: { $0.destination?.settings }, action: { .destination(.presented(.settings($0))) }, descriptor: settings)
    for face in IndexedCubeFace.cubeIndices {
      let id = Self.faceID(face)
      game = game.operation("select-" + id, label: "Select cube face " + id, action: .tap(.began, face), available: { state in
        state.destination == nil && state.isGameLoaded && state.optimisticallySelectedFace == nil && !state.selectedWord.contains(face)
          && state.cubes.isPlayable(side: face.side, index: face.index)
          && (state.selectedWord.last.map { $0.isTouching(face) } ?? true)
      })
    }
    let descriptor = FeatureDescriptor<AppReducer.State, AppReducer.Action>("isowords", observation: { state in
      .object([
        "home": .object(["visible": .bool(state.destination == nil), "soloOpen": .bool(state.home.destination?.solo != nil),
          "settingsOpen": .bool(state.home.destination?.settings != nil), "hasSavedUnlimited": .bool(state.home.savedGames.unlimited != nil)]),
        "settings": (state.destination?.game?.destination?.settings ?? state.home.destination?.settings).map(Self.settingsSnapshot) ?? .null,
        "game": state.destination?.game.map(Self.gameSnapshot) ?? .null
      ])
    })
      .child("home", state: { $0.destination == nil ? $0.home : nil }, action: { .home($0) }, descriptor: home)
      .child("game", state: { $0.destination?.game }, action: { .destination(.presented(.game($0))) }, descriptor: game)
    return store.harness(descriptor: descriptor, verify: { root, condition in
      let game = root.destination?.game
      switch condition {
      case "soloOpen": return root.home.destination?.solo != nil
      case "gameReady": return game?.isGameLoaded == true
      case "wordAccepted": return (game?.playedWords.count ?? 0) > 0 && (game?.currentScore ?? 0) > 0
      default:
        if condition.hasPrefix("selected:") {
          return game?.selectedWordString == String(condition.dropFirst("selected:".count)) && game?.optimisticallySelectedFace == nil
        }
        return nil
      }
    })
  }


  static func settingsSnapshot(_ state: Settings.State) -> HarnessValue {
    .object(["colorScheme": .string(state.userSettings.colorScheme.rawValue),
      "reducedAnimation": .bool(state.userSettings.enableReducedAnimation),
      "haptics": .bool(state.userSettings.enableHaptics),
      "musicVolume": .number(Double(state.userSettings.musicVolume))])
  }

  static func faceID(_ face: IndexedCubeFace) -> String {
    "\(face.index.x.rawValue)-\(face.index.y.rawValue)-\(face.index.z.rawValue)-\(face.side.rawValue)"
  }

  static func gameSnapshot(_ state: Game.State) -> HarnessValue {
    let faces = IndexedCubeFace.cubeIndices.filter { state.cubes.isPlayable(side: $0.side, index: $0.index) }
    return .object([
      "menuOpen": .bool(state.destination?.bottomMenu != nil),
      "settingsOpen": .bool(state.destination?.settings != nil),
      "ready": .bool(state.isGameLoaded),
      "mode": .string(String(describing: state.gameMode)),
      "score": .number(Double(state.currentScore)),
      "selectedWord": .string(state.selectedWordString),
      "valid": .bool(state.selectedWordIsValid),
      "holdingFace": state.optimisticallySelectedFace.map { .string(faceID($0)) } ?? .null,
      "playedWords": .array(state.playedWords.map { .object(["word": .string($0.word), "score": .number(Double($0.score))]) }),
      "faces": .array(faces.map { face in .object([
        "id": .string(faceID(face)), "letter": .string(state.cubes[face].letter),
        "neighbors": .array(faces.filter(face.isTouching).map { .string(faceID($0)) })
      ]) })
    ])
  }
}

/// Offline launch configuration only. Game rules, dictionary, puzzle generation,
/// navigation and rendering are the upstream implementations.
func configureHarnessDependencies(_ values: inout DependencyValues) {
  values.apiClient = .noop
  values.applicationClient = .noop
  values.audioPlayer = .noop
  values.build = .noop
  values.database = .inMemory
  values.deviceId = .noop
  values.fileClient = .noop
  values.gameCenter = .noop
  values.lowPowerMode = .false
  values.remoteNotifications = .noop
  values.serverConfig = .noop
  values.storeKit = .noop
  values.userDefaults = .noop
  values.userDefaults.override(bool: true, forKey: "hasShownFirstLaunchOnboardingKey")
  values.userSettings = .mock()
  values.userNotifications = .noop
}

private struct VolumeInput: HarnessInput {
  let value: Double
  static var harnessSchema: HarnessJSONSchema { .object(["value": .boundedNumber(0...1)]) }
}
