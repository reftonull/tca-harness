import AppFeature
import ComposableArchitecture
import DictionarySqliteClient
import Foundation
import GameCore
import HomeFeature
import SoloFeature
import TCAHarnessTCA1

/// The upstream isowords `AppReducer` with no UI, served by the same descriptor as the iOS example.
///
/// Usage: `isowords-headless [--port 8790]`
@main
@MainActor
enum IsowordsHeadless {
  static func main() {
    let arguments = CommandLine.arguments
    let port = arguments.firstIndex(of: "--port").flatMap { arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil } ?? 8790
    // Record for `tca devtools` without requiring TCA_HARNESS=1.
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: AppReducer.State()) {
      AppReducer().headlessViewLifecycle().harnessTimeline(timeline).transformDependency(\.self) {
        configureHarnessDependencies(&$0)
      }
    }
    let harness = EmbeddedIsowordsHarness.attach(to: store, timeline: timeline)
    store.send(.appDelegate(.didFinishLaunching))
    store.send(.home(.task))  // HomeView's `.task`; Home is on screen at launch.
    Task {
      do { try await harness.runHeadless(port: port) } catch {
        FileHandle.standardError.write(Data("isowords-headless: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
      exit(0)
    }
    // A run loop rather than `async main`: upstream schedules timers on RunLoop.main.
    RunLoop.main.run()
  }
}

extension Reducer where Self == AppReducer {
  /// Sends the `.task` actions the SwiftUI views send when Solo and Game appear. Their effects run in
  /// the presented feature's scope, so TCA cancels them on dismissal, as SwiftUI cancels `.task`.
  func headlessViewLifecycle() -> some ReducerOf<AppReducer> {
    self
      .onChange(of: { $0.home.destination?.solo != nil }) { _, isPresented in
        Reduce { _, _ in isPresented ? .send(.home(.destination(.presented(.solo(.task))))) : .none }
      }
      .onChange(of: { $0.destination?.game != nil }) { _, isPresented in
        Reduce { _, _ in isPresented ? .send(.destination(.presented(.game(.task)))) : .none }
      }
  }
}
