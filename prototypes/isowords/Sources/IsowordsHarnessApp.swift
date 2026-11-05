import ApiClient
import ComposableArchitecture
import HomeFeature
import SettingsFeature
import TCAHarnessTCA1
import Styleguide
import SwiftUI
import TCAHarness

@main
struct IsowordsHarnessApp: App {
  static let store = Store(initialState: IsowordsRoot.State()) {
    IsowordsRoot()
  } withDependencies: {
    $0.apiClient = .noop
    $0.applicationClient = .noop
    $0.audioPlayer = .noop
    $0.build = .noop
    $0.database = .inMemory
    $0.deviceId = .noop
    $0.gameCenter = .noop
    $0.remoteNotifications = .noop
    $0.serverConfig = .noop
    $0.storeKit = .noop
    $0.userDefaults = .noop
    $0.userSettings = .mock()
    $0.userNotifications = .noop
  }

  static let runtime = HarnessRuntime(descriptor: IsowordsRoot.harnessDescriptor
    .presentation("releasePlan", state: \.plan, action: \.plan, descriptor: ReleasePlan.runtimeDescriptor),
    read: { store.withState { $0 } }, send: { store.send($0) }, verify: { root, condition in
      let state = root.home
      switch condition {
      case "planPublished": return root.plan?.phase == "published" && root.plan?.items.count == 3 && root.plan?.items.allSatisfy(\.isComplete) == true
      case "settingsOpen": return state.destination?.settings != nil
      case "settingsClosed": return state.destination?.settings == nil
      case "hapticsOff": return state.destination?.settings?.userSettings.enableHaptics == false
      case "reducedAnimationOn": return state.destination?.settings?.userSettings.enableReducedAnimation == true
      case "musicMuted": return state.destination?.settings?.userSettings.musicVolume == 0
      default: return nil
      }
    })
  static let session = runtime.session
  static let server = HarnessServer { await session.handleJSON($0) }

  init() { Styleguide.registerFonts() }

  var body: some Scene {
    WindowGroup {
      HarnessRootView(store: Self.store)
        .task {
          do { try Self.server.start(port: 8766) }
          catch { print("Harness startup: \(error)") }
          print("Mounted features: \(Self.runtime.inspect().map(\.path))")
        }
    }
  }
}

struct HarnessRootView: View {
  @Bindable var store: StoreOf<IsowordsRoot>
  var body: some View {
    NavigationStack {
      HomeView(store: store.scope(state: \.home, action: \.home))
        .safeAreaInset(edge: .bottom) {
          Button("Open workflow demo") { store.send(.openPlannerButtonTapped) }
            .buttonStyle(.borderedProminent).tint(.indigo).padding()
        }
    }
    .sheet(item: $store.scope(state: \.plan, action: \.plan)) { ReleasePlanView(store: $0) }
  }
}
