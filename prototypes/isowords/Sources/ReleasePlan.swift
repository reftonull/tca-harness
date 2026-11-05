import ComposableArchitecture
import SwiftUI
import TCAHarness
import TCAHarnessTCA1

@HarnessSchema
struct ReleaseTaskInput: Codable {
  var title: String
  var owner: String
  var priority: ReleasePriority
  var notes: String
}

@HarnessSchema
enum ReleasePriority: String, Codable {
  case normal
  case high
}

@HarnessSchema
struct ReleasePlanInput: Codable {
  var title: String
  var summary: String
  var tasks: [ReleaseTaskInput]
}

@HarnessFeature
@Reducer
struct ReleaseTask {
  @ObservableState
  struct State: Identifiable {
    var id: Int
    var title: String
    var owner: String
    var priority: String
    var notes: String
    var isComplete = false
  }
  enum Action {
    case completeButtonTapped
  }
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .completeButtonTapped: state.isComplete = true
      }
      return .none
    }
  }
}

@HarnessFeature
@Reducer
struct ReleasePlan {
  @ObservableState
  struct State {
    var title = "Ready for a plan"
    var summary = "The agent will generate a structured plan, complete each task, then publish it locally."
    var items: IdentifiedArrayOf<ReleaseTask.State> = []
    var phase = "draft"
    var activity = "Waiting for the agent"
    var completedCount: Int { items.filter(\.isComplete).count }
  }
  enum Action {
    @HarnessIgnore case create(ReleasePlanInput)
    case items(IdentifiedActionOf<ReleaseTask>)
    @HarnessIgnore case publishButtonTapped
    @HarnessIgnore case publishResponse
    @HarnessIgnore case cancelPublish
  }
  enum CancelID { case publish }
  @Dependency(\.continuousClock) var clock

  @MainActor static var runtimeDescriptor: FeatureDescriptor<State, Action> {
    harnessDescriptor
      .operation("createPlan", label: "Create a release plan with exactly three tasks, owners, priorities and original implementation notes",
        arguments: ReleasePlanInput.self, action: Action.create, available: { $0.items.isEmpty },
        validate: { _, input in
          guard input.tasks.count == 3, !input.title.trimmingCharacters(in: .whitespaces).isEmpty,
            input.tasks.allSatisfy({ !$0.title.isEmpty && !$0.owner.isEmpty && $0.notes.count >= 30 }) else {
            throw HarnessArgumentError("Supply exactly three named tasks with owners and at least 30 characters of notes each")
          }
        })
      .operation("publishPlan", label: "Publish the completed release plan locally (asynchronous save)", action: .publishButtonTapped,
        available: { $0.phase == "draft" && $0.items.count == 3 && $0.items.allSatisfy(\.isComplete) },
        completion: { $0.phase == "published" ? .succeeded : .running }, cancel: .cancelPublish)
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .create(input):
        state.title = input.title
        state.summary = input.summary
        state.items = IdentifiedArray(uniqueElements: input.tasks.enumerated().map { index, task in
          ReleaseTask.State(id: index + 1, title: task.title, owner: task.owner, priority: task.priority.rawValue, notes: task.notes)
        })
        state.activity = "Structured plan decoded and dispatched"
        return .none
      case let .items(.element(id, .completeButtonTapped)):
        state.activity = "Child task \(id) completed through its identified route"
        return .none
      case .publishButtonTapped:
        guard state.items.count == 3, state.items.allSatisfy(\.isComplete), state.phase == "draft" else { return .none }
        state.phase = "saving"
        state.activity = "Saving locally • simulated 2-second effect"
        return .run { send in
          try await clock.sleep(for: .seconds(2))
          await send(.publishResponse)
        }
        .cancellable(id: CancelID.publish)
      case .publishResponse:
        state.phase = "published"
        state.activity = "Publish verified from reducer state"
        return .none
      case .cancelPublish:
        state.phase = "draft"
        state.activity = "Publish cancelled"
        return .cancel(id: CancelID.publish)
      }
    }
    .forEach(\.items, action: \.items) { ReleaseTask() }
  }
}

struct ReleasePlanView: View {
  let store: StoreOf<ReleasePlan>
  private let ink = Color(red: 0.10, green: 0.15, blue: 0.24)
  private let accent = Color(red: 0.26, green: 0.28, blue: 0.77)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Label("RELEASE WORKSPACE", systemImage: "shippingbox")
            .font(.caption.weight(.bold)).tracking(1)
          Spacer()
          Text("LIVE TCA").font(.caption2.weight(.bold)).foregroundStyle(accent)
        }
        .foregroundStyle(.secondary)
        Text(store.title).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(ink)
        Text(store.summary).font(.subheadline).foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Image(systemName: "sparkles")
          Text("Jev chooses • LLM writes • TCA executes").font(.caption.weight(.medium))
        }.foregroundStyle(accent)
        if store.items.isEmpty {
          VStack(spacing: 14) {
            Image(systemName: "list.bullet.clipboard").font(.system(size: 40)).foregroundStyle(accent)
            Text("Waiting for structured input").font(.headline)
            Text("Three tasks will appear here from one typed action, including owners, priorities and generated notes.")
              .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity).padding(30).background(.white, in: RoundedRectangle(cornerRadius: 20))
        }
        ForEach(store.items) { item in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
              .font(.title2).foregroundStyle(item.isComplete ? .green : .gray.opacity(0.35))
            VStack(alignment: .leading, spacing: 7) {
              Text(item.title).font(.headline).foregroundStyle(ink)
              HStack {
                Text(item.owner)
                Text("·")
                Text(item.priority.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(item.priority == "high" ? .orange : accent)
                Spacer()
                Text("TASK \(item.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
              }.font(.caption).foregroundStyle(.secondary)
              Text(item.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
          }
          .padding(16).frame(maxWidth: .infinity, alignment: .leading)
          .background(.white, in: RoundedRectangle(cornerRadius: 18))
        }
      }.padding(22)
    }
    .background(Color(red: 0.95, green: 0.96, blue: 0.98))
    .safeAreaInset(edge: .bottom) {
      VStack(alignment: .leading, spacing: 9) {
        HStack {
          if store.phase == "saving" { ProgressView() }
          Image(systemName: store.phase == "published" ? "checkmark.seal.fill" : "arrow.triangle.branch")
            .foregroundStyle(store.phase == "published" ? .green : accent)
          Text(store.phase == "published" ? "Published locally" : store.phase == "saving" ? "Publishing…" : "\(store.completedCount) of \(store.items.count) complete")
            .font(.headline)
          Spacer()
        }
        Text(store.activity).font(.caption).foregroundStyle(.secondary)
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
    }
    .presentationDragIndicator(.visible)
  }
}
