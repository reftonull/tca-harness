import ComposableArchitecture
import Foundation
@testable import TCAHarnessCore
@testable import TCAHarness
import Testing

// MARK: Vanilla SwiftUI-style models

@HarnessSchema
struct ApproveInput: Codable {
  var id: Int
}

struct ApprovalError: Error {}

@MainActor @Observable
final class ExpensesModel {
  struct Expense: Equatable {
    var id: Int
    var merchant: String
    var approved = false
  }
  var expenses: [Expense] = []
  var isLoading = false
  var pendingCount = 0
  var receipt: ReceiptModel?
  /// Planted bug: approving forgets to update the pending count.
  var forgetsCount = false

  func load() async {
    isLoading = true
    try? await Task.sleep(for: .milliseconds(30))
    expenses = [Expense(id: 1, merchant: "Blue Bottle"), Expense(id: 2, merchant: "Delta")]
    pendingCount = 2
    isLoading = false
  }

  func approve(id: Int) async throws {
    guard let index = expenses.firstIndex(where: { $0.id == id }) else { throw ApprovalError() }
    expenses[index].approved = true
    if !forgetsCount { pendingCount -= 1 }
  }

  func openReceipt(id: Int) {
    receipt = expenses.first { $0.id == id }.map { ReceiptModel(merchant: $0.merchant) }
  }
}

@MainActor @Observable
final class ReceiptModel {
  var merchant: String
  var note = ""
  init(merchant: String) { self.merchant = merchant }
}

extension ReceiptModel {
  static var harnessDescriptor: ModelDescriptor<ReceiptModel> {
    .model("Receipt")
      .operation("note", label: "Add note", arguments: String.self) { $0.note = $1 }
  }
}

extension ExpensesModel {
  static var harnessDescriptor: ModelDescriptor<ExpensesModel> {
    .model("Expenses")
      .operation("load", label: "Load expenses", available: { !$0.isLoading }) { await $0.load() }
      .operation("approve", label: "Approve", arguments: ApproveInput.self,
        available: { $0.pendingCount > 0 }) { try await $0.approve(id: $1.id) }
      .operation("openReceipt", label: "Open receipt", arguments: ApproveInput.self) { $0.openReceipt(id: $1.id) }
      .invariant("pending count matches unapproved") { $0.pendingCount == $0.expenses.filter { !$0.approved }.count }
      .model("receipt", { $0.receipt }, descriptor: ReceiptModel.harnessDescriptor)
  }
}

// MARK: A TCA app that hosts the model two ways

@Reducer
struct Wallet {
  struct State {
    /// A vanilla screen kept as a plain reference, mounted with `.model`.
    var settings: ExpensesModel
    /// The same kind of model hosted in the store with `Hosted`.
    var expenses: Hosted<ExpensesModel>.State
    @MainActor init() {
      settings = ExpensesModel()
      expenses = Hosted<ExpensesModel>.State(ExpensesModel())
    }
  }
  enum Action {
    case expenses(Hosted<ExpensesModel>.Action)
  }
  var body: some ReducerOf<Self> {
    Scope(state: \.expenses, action: \.expenses) { Hosted<ExpensesModel>() }
  }
}

/// A vanilla model with an injected client (a struct of closures) and a slow load.
@MainActor @Observable
final class SlowModel {
  struct Client: Sendable { var fetch: @Sendable () async throws -> Int }
  var value = 0
  var isLoading = false
  var sawCancellation = false
  private let client: Client

  nonisolated init(client: Client = Client(fetch: { try await Task.sleep(for: .seconds(30)); return 1 })) {
    self.client = client
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do { value = try await client.fetch() } catch { sawCancellation = Task.isCancelled }
  }
}

extension SlowModel {
  static var harnessDescriptor: ModelDescriptor<SlowModel> {
    .model("Slow").operation("load", label: "Load", available: { !$0.isLoading }) { await $0.load() }
  }
}

/// Presents a hosted model as a sheet and starts its load, as an app's parent feature would.
@Reducer
struct Reader {
  @ObservableState
  struct State: Equatable {
    @Presents var slow: Hosted<SlowModel>.State?
  }
  enum Action {
    case openButtonTapped
    case slow(PresentationAction<Hosted<SlowModel>.Action>)
  }
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .openButtonTapped:
        state.slow = Hosted.State(SlowModel())
        return .send(.slow(.presented(.call("load") { await $0.load() })))
      case .slow:
        return .none
      }
    }
    .ifLet(\.$slow, action: \.slow) { Hosted<SlowModel>() }
  }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
  for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  #expect(condition())
}

@MainActor
private func waitFor(_ client: Client, _ response: [String: Any]) async throws -> String? {
  let receipt = try #require(response["receipt"] as? [String: Any])
  let waited = try await client.call("wait", ["requestID": receipt["requestID"]!, "timeoutMs": 2000])
  return (waited["receipt"] as? [String: Any])?["status"] as? String
}

@Suite(.serialized) @MainActor
struct ModelHarnessTests {
  @Test func vanillaModelIsObservedAndDrivenLikeAFeature() async throws {
    let model = ExpensesModel()
    let harness = ModelHarness(model, descriptor: ExpensesModel.harnessDescriptor, issues: HarnessIssueLog())
    let client = Client(harness.runtime.session)
    _ = try await client.call("observe")
    let state = try #require(client.observation["state"] as? [String: Any])
    #expect(state["isLoading"] as? Bool == false)
    #expect(state.keys.allSatisfy { !$0.hasPrefix("$") && !$0.contains("observationRegistrar") })
    // Approve is unavailable until something is pending.
    #expect(throws: (any Error).self) { try client.id("root/approve@") }

    let load = try await client.dispatch(client.id("root/load@"))
    #expect(load["ok"] as? Bool == true)
    #expect(try await waitFor(client, load) == "succeeded")
    #expect(model.expenses.count == 2)

    let approve = try await client.dispatch(client.id("root/approve@"), arguments: ["id": 1])
    #expect(try await waitFor(client, approve) == "succeeded")
    #expect(model.pendingCount == 1 && model.expenses[0].approved)

    let invalid = try await client.dispatch(client.id("root/approve@"), arguments: ["id": "one"])
    #expect(invalid["error"] as? String == "invalid_arguments")
  }

  @Test func nestedModelsMountWhileTheyExist() async throws {
    let model = ExpensesModel()
    await model.load()
    let harness = ModelHarness(model, descriptor: ExpensesModel.harnessDescriptor, issues: HarnessIssueLog())
    let client = Client(harness.runtime.session)
    _ = try await client.call("observe")
    #expect(harness.runtime.inspect().map(\.path) == ["root"])
    let open = try await client.dispatch(client.id("root/openReceipt@"), arguments: ["id": 2])
    #expect(try await waitFor(client, open) == "succeeded")
    #expect(harness.runtime.inspect().map(\.path) == ["root", "root/receipt"])
    let note = try await client.dispatch(client.id("root/receipt/note@"), arguments: ["value": "team lunch"])
    #expect(try await waitFor(client, note) == "succeeded")
    #expect(model.receipt?.note == "team lunch")
    let state = try #require(client.observation["state"] as? [String: Any])
    #expect((state["receipt"] as? [String: Any])?["merchant"] as? String == "Delta")
  }

  @Test func thrownErrorsAndBrokenInvariantsBecomeIssues() async throws {
    let model = ExpensesModel()
    model.forgetsCount = true
    await model.load()
    let issues = HarnessIssueLog()
    let harness = ModelHarness(model, descriptor: ExpensesModel.harnessDescriptor, issues: issues)
    let client = Client(harness.runtime.session)
    _ = try await client.call("observe")

    let approve = try await client.dispatch(client.id("root/approve@"), arguments: ["id": 1])
    #expect(try await waitFor(client, approve) == "succeeded")
    _ = try await client.call("observe")
    #expect(issues.issues().map(\.message) == ["root: pending count matches unapproved"])

    let missing = try await client.dispatch(client.id("root/approve@"), arguments: ["id": 99])
    #expect(try await waitFor(client, missing) == "failed")
    #expect(issues.issues().last?.message.hasPrefix("ExpensesModel.approve threw:") == true)
  }

  @Test func modelsInsideATCAAppAreMountedAndObserved() async throws {
    let store = Store(initialState: Wallet.State()) { Wallet() }
    let descriptor = FeatureDescriptor<Wallet.State, Wallet.Action>("Wallet", observation: { _ in .object([:]) })
      .model("settings", { $0.settings }, descriptor: ExpensesModel.harnessDescriptor)
      .child("expenses", state: \.expenses, action: \.expenses, descriptor: Hosted.descriptor(ExpensesModel.harnessDescriptor))
    let harness = store.harness(descriptor: descriptor, timeline: nil, issues: HarnessIssueLog())
    let client = Client(harness.runtime.session)
    _ = try await client.call("inspect")
    #expect(Set(harness.runtime.inspect().map(\.path)) == ["root", "root/settings", "root/expenses"])

    // `.model`: calls the model directly.
    let direct = try await client.dispatch(client.id("root/settings/load@"))
    #expect(try await waitFor(client, direct) == "succeeded")
    #expect(store.withState { $0.settings.expenses.count } == 2)
    let state = try #require(client.observation["state"] as? [String: Any])
    #expect(((state["settings"] as? [String: Any])?["expenses"] as? [Any])?.count == 2)

    // `Hosted`: the same call goes through the store as an effect.
    let hosted = try await client.dispatch(client.id("root/expenses/load@"))
    #expect(try await waitFor(client, hosted) == "succeeded")
    #expect(store.withState { $0.expenses.model.expenses.count } == 2)
    #expect(store.withState { $0.expenses.running }.isEmpty)
    // What a view does: `ExpensesView(model: store.model)` on the scoped store.
    let scoped = store.scope(state: \.expenses, action: \.expenses)
    #expect(scoped.model === store.withState { $0.expenses.model })
  }

  @Test(.enabled(if: HarnessServer.isAvailable, "Timelines record only in DEBUG builds"))
  func hostedModelCallsAppearInTheTimeline() async throws {
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: Wallet.State()) { Wallet().harnessTimeline(timeline) }
    let descriptor = FeatureDescriptor<Wallet.State, Wallet.Action>("Wallet")
      .child("expenses", state: \.expenses, action: \.expenses, descriptor: Hosted.descriptor(ExpensesModel.harnessDescriptor))
    let harness = store.harness(descriptor: descriptor, timeline: timeline, issues: HarnessIssueLog())
    let client = Client(harness.runtime.session)
    _ = try await client.call("observe")
    let load = try await client.dispatch(client.id("root/expenses/load@"))
    #expect(try await waitFor(client, load) == "succeeded")
    let entries = try #require(timeline.page(since: 0)).entries.sorted { $0.index < $1.index }
    #expect(entries.map { $0.action.joined(separator: ".") } == ["expenses.perform.load", "expenses.finished.load"])
    // The model is a reference, but each entry shows it as of that action, so the call's changes
    // land on `finished`.
    #expect(entries[0].changes == [])
    #expect(entries[1].changes.contains("expenses.expenses"))
    #expect(entries[1].changes.contains("expenses.pendingCount"))
  }

  @Test func dismissingAHostedModelCancelsItsCalls() async throws {
    let store = Store(initialState: Reader.State()) { Reader() }
    let descriptor = FeatureDescriptor<Reader.State, Reader.Action>("Reader")
      .operation("open", label: "Open", action: .openButtonTapped)
      .presentation("slow", state: \.slow, action: \.slow,
        descriptor: Hosted.descriptor(SlowModel.harnessDescriptor).operation("close", label: "Close", action: .dismiss))
    let harness = store.harness(descriptor: descriptor, timeline: nil, issues: HarnessIssueLog())
    let client = Client(harness.runtime.session)
    _ = try await client.call("observe")
    _ = try await client.dispatch(client.id("root/open@"))
    let model = try #require(store.withState { $0.slow?.model })
    // The parent's `.call` started the load as an effect of the sheet.
    try await eventually { model.isLoading }
    #expect(store.withState { $0.slow?.running } == ["load": 1])

    // A parent's reflected observation shows the hosted model's stored properties, without its client.
    _ = try await client.call("observe")
    let state = try #require(client.observation["state"] as? [String: Any])
    let slow = try #require(state["slow"] as? [String: Any])
    #expect(slow["isLoading"] as? Bool == true)
    #expect(slow["client"] == nil)

    _ = try await client.dispatch(client.id("root/slow/close@"))
    try await eventually { store.withState { $0.slow } == nil }
    try await eventually { model.sawCancellation }
    #expect(model.value == 0)
  }

  @Test func closuresAreLeftOutOfSnapshots() {
    let snapshot = StateInspection.snapshot(SlowModel(), reflectingObjects: true)
    guard case let .object(fields) = snapshot else { Issue.record("expected an object"); return }
    #expect(Set(fields.keys) == ["value", "isLoading", "sawCancellation"])
    struct Mixed { var name = "a"; var action: () -> Void = {} }
    #expect(StateInspection.snapshot(Mixed()) == .object(["name": .string("a")]))
  }
}
