import ComposableArchitecture
import Foundation
import IssueReportingTestSupport
@testable import TCAHarness
import Testing

@HarnessSchema
struct DetailInput: Codable {
  var enabled: Bool
  var tags: [String]
}

@HarnessSchema
enum PriorityInput: String, Codable {
  case normal
  case urgent = "high"
}

@HarnessSchema
struct RenameInput: Codable {
  var title: String
  var count: Int
  var priority: PriorityInput
  var detail: DetailInput
  var note: String?
}

@HarnessFeature
@Reducer
struct ItemFeature {
  @ObservableState
  struct State: Identifiable {
    var id: Int
    var count = 0
    var title = ""
    var password = "never-export-this"
    @HarnessIgnore var privateNotes = "also-private"
  }
  enum Action {
    case incrementButtonTapped
    @HarnessOperation("Rename item with structured details")
    case rename(RenameInput)
    @HarnessOperation("Set priority")
    case priority(PriorityInput)
  }
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .incrementButtonTapped: state.count += 1
      case let .rename(input): state.title = input.title; state.count = input.count
      case let .priority(value): state.title = value.rawValue
      }
      return .none
    }
  }
}

@HarnessFeature
@Reducer
struct WorkspaceFeature {
  @ObservableState
  struct State {
    var child: ItemFeature.State?
    var items: IdentifiedArrayOf<ItemFeature.State> = [.init(id: 1), .init(id: 2)]
    var path: StackState<ItemFeature.State> = StackState()
    var isSaving = false
    var saved = false
    // State deliberately cannot synthesize Codable.
    var opaque = NSObject()
  }
  enum Action {
    case child(ItemFeature.Action)
    case items(IdentifiedActionOf<ItemFeature>)
    case path(StackActionOf<ItemFeature>)
    case openButtonTapped
    case closeButtonTapped
    @HarnessIgnore case saveButtonTapped
    @HarnessIgnore case saveResponse
    @HarnessIgnore case cancelSave
  }
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .openButtonTapped: state.child = .init(id: 9)
      case .closeButtonTapped: state.child = nil
      case .saveButtonTapped: state.isSaving = true; state.saved = false
      case .saveResponse: state.isSaving = false; state.saved = true
      case .cancelSave: state.isSaving = false
      default: break
      }
      return .none
    }
    .ifLet(\.child, action: \.child) { ItemFeature() }
    .forEach(\.items, action: \.items) { ItemFeature() }
    .forEach(\.path, action: \.path) { ItemFeature() }
  }
}

enum DescribedMode: CustomStringConvertible {
  case quiet
  var description: String { "described-secret" }
}

@HarnessFeature
@Reducer
struct TimelineFeature {
  @ObservableState
  struct State {
    var count = 0
    var saved = false
    var title = ""
    var password = "never-export-this"
    @HarnessIgnore var privateNotes = "also-private"
    var items: IdentifiedArrayOf<ItemFeature.State> = [.init(id: 1)]
  }
  enum Action {
    case incrementButtonTapped
    case save
    case saveResponse
    case response(Int)
    case titleChanged(String)
    case tagged([String: String])
    case mode(DescribedMode)
    case items(IdentifiedActionOf<ItemFeature>)
  }
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .incrementButtonTapped: state.count += 1
      case .save: return .run { send in await send(.saveResponse) }
      case .saveResponse: state.saved = true
      case let .response(value): state.count = value
      case let .titleChanged(title): state.title = title
      case .tagged, .mode, .items: break
      }
      return .none
    }
    .forEach(\.items, action: \.items) { ItemFeature() }
  }
}

@MainActor
final class Client {
  let session: HarnessSession<HarnessValue>
  var observation: [String: Any] = [:]
  init(_ session: HarnessSession<HarnessValue>) { self.session = session }
  func call(_ method: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
    var request = fields; request["method"] = method
    if let id = observation["sessionID"] { request["sessionID"] = id }
    let response = try JSONSerialization.jsonObject(with: await session.handleJSON(JSONSerialization.data(withJSONObject: request))) as! [String: Any]
    if let next = response["observation"] as? [String: Any] { observation = next }
    return response
  }
  func id(_ fragment: String) throws -> String {
    let matches = (observation["candidates"] as! [[String: Any]]).compactMap { $0["id"] as? String }.filter { $0.contains(fragment) }
    guard matches.count == 1 else { throw HarnessArgumentError("Expected one operation for \(fragment): \(matches)") }
    return matches[0]
  }
  func dispatch(_ id: String, arguments: [String: Any] = [:], requestID: String = UUID().uuidString) async throws -> [String: Any] {
    try await call("dispatch", ["candidateID": id, "revision": observation["revision"]!, "requestID": requestID, "arguments": arguments])
  }
}

@Suite @MainActor
struct RuntimeTests {
  private func fixture() -> (StoreOf<WorkspaceFeature>, HarnessRuntime<WorkspaceFeature.State, WorkspaceFeature.Action>) {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let descriptor = WorkspaceFeature.harnessDescriptor.operation("save", action: .saveButtonTapped,
      available: { !$0.isSaving }, completion: { $0.saved ? .succeeded : .running }, cancel: .cancelSave)
    return (store, HarnessRuntime(descriptor: descriptor, read: { store.withState { $0 } }, send: { store.send($0) }))
  }

  @Test func inspectReportsDeclaredAndUnexposedActions() async throws {
    let (_, runtime) = fixture()
    let features = try await Client(runtime.session).call("inspect")["features"] as! [[String: Any]]
    let root = features.first { $0["path"] as? String == "root" }!
    // saveButtonTapped is @HarnessIgnore'd, but the fixture's "save" operation sends it.
    let unexposed = (root["unexposed"] as! [[String: String]]).map { "\($0["action"]!): \($0["reason"]!)" }
    #expect(unexposed == ["saveResponse: ignored", "cancelSave: ignored"])
    #expect((root["declaredOperations"] as! [[String: String]]).map { $0["id"]! } == ["openButtonTapped", "closeButtonTapped", "save"])
    let item = features.first { $0["path"] as? String == "root/items/1" }!
    #expect((item["unexposed"] as! [Any]).isEmpty)
    // The catalog lists what can be mounted, mounted or not; it is only sent when asked for.
    let client = Client(runtime.session)
    #expect(try await client.call("inspect")["catalog"] == nil)
    let catalog = try await client.call("inspect", ["catalog": true])["catalog"] as! [[String: Any]]
    #expect(catalog.map { $0["path"] as! String } == ["root", "root/child", "root/items/{id}", "root/path/{id}"])
    #expect((catalog[1]["declaredOperations"] as! [[String: String]]).map { $0["id"]! } == ["incrementButtonTapped", "rename", "priority"])

    let store = Store(initialState: TimelineFeature.State()) { TimelineFeature() }
    let descriptor = TimelineFeature.harnessDescriptor
      .operation("setTitle", label: "Set title", arguments: String.self, action: { .titleChanged($0) })
      .operation("finish", action: .saveResponse)
      .unexposed("swipe", reason: "needs a gesture")
    let explicit = HarnessRuntime(descriptor: descriptor, read: { store.withState { $0 } }, send: { store.send($0) })
    let info = explicit.inspect().first { $0.path == "root" }!
    #expect(info.unexposed.map { "\($0.action): \($0.reason)" } == [
      "save: unannotated", "response: unsupported payload", "tagged: unsupported payload",
      "mode: unsupported payload", "swipe: needs a gesture",
    ])
  }

  @Test func generatedAttachmentUsesTheExistingStore() async throws {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let attachment = store.harness(WorkspaceFeature.self)
    let client = Client(attachment.runtime.session)
    _ = try await client.call("inspect")
    let response = try await client.dispatch(client.id("root/openButtonTapped@"))
    #expect(response["ok"] as? Bool == true)
    #expect(store.withState { $0.child?.id } == 9)
    #expect(attachment.runtime.inspect().contains { $0.path == "root/child" })
  }

  @Test func listenerIsOptInAndInvalidConfigurationIsActionable() throws {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let attachment = store.harness(WorkspaceFeature.self)
    #expect(try attachment.startIfEnabled(environment: [:]) == false)
    #expect(try attachment.startIfEnabled(environment: ["TCA_HARNESS": "0", "TCA_HARNESS_PORT": "8767"]) == false)
    #expect(try attachment.startIfEnabled(environment: ["TCA_HARNESS_PORT": "8767"]) == false)
    #expect(attachment.server.status == "Stopped")
    // Without DEBUG the environment is not consulted at all; see the test below.
    for port in ["", "0", "-1", "65536", "invalid"] where HarnessServer.isAvailable {
      do {
        try attachment.startIfEnabled(environment: ["TCA_HARNESS": "1", "TCA_HARNESS_PORT": port])
        Issue.record("Invalid port unexpectedly accepted: \(port)")
      } catch {
        #expect(error.localizedDescription.contains("TCA_HARNESS_PORT"))
      }
    }
    attachment.stop()
    attachment.stop()
    #expect(attachment.server.status == "Stopped")
    #expect(store.withState { $0.child } == nil)
  }

  @Test(.enabled(if: HarnessServer.isAvailable, "The listener exists only in DEBUG builds"))
  func headlessHostServesTheStoreOverLoopbackUntilStopped() async throws {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let attachment = store.harness(WorkspaceFeature.self, timeline: nil)
    let port = UInt16.random(in: 20000...29999)
    let host = Task { try await attachment.runHeadless(port: port) }
    while !attachment.server.status.hasPrefix("Listening") { try await Task.sleep(for: .milliseconds(5)) }

    let replies = try await Task.detached {
      let socket = try LineSocket(port: port)
      let observed = try socket.call(["method": "observe"])
      let observation = observed["observation"] as! [String: Any]
      let candidate = (observation["candidates"] as! [[String: Any]])
        .compactMap { $0["id"] as? String }.first { $0.contains("root/openButtonTapped@") }!
      let dispatched = try socket.call(["method": "dispatch", "sessionID": observation["sessionID"]!,
        "revision": observation["revision"]!, "requestID": "headless-1", "candidateID": candidate, "arguments": [:]])
      return (observed["ok"] as? Bool, dispatched["ok"] as? Bool)
    }.value
    #expect(replies.0 == true && replies.1 == true)
    #expect(store.withState { $0.child?.id } == 9)

    attachment.stop()
    try await host.value
    #expect(attachment.server.status == "Stopped")
  }

  @Test(.enabled(if: HarnessServer.isAvailable, "The listener exists only in DEBUG builds"))
  func headlessHostEndsWhenItsTaskIsCancelled() async throws {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let attachment = store.harness(WorkspaceFeature.self, timeline: nil)
    let host = Task { try await attachment.runHeadless(port: UInt16.random(in: 30000...39999)) }
    while !attachment.server.status.hasPrefix("Listening") { try await Task.sleep(for: .milliseconds(5)) }
    host.cancel()
    try await host.value
    #expect(attachment.server.status == "Stopped")
  }

  /// Run with `swift test -c release -Xswiftc -enable-testing` to check the release side.
  @Test func listenerAndTimelineAreCompiledOutWithoutDebug() async throws {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let attachment = store.harness(WorkspaceFeature.self, timeline: nil)
    let timeline = HarnessTimeline(isEnabled: true)
    #if DEBUG
    #expect(HarnessServer.isAvailable)
    #expect(timeline.isEnabled)
    #else
    #expect(!HarnessServer.isAvailable)
    #expect(!timeline.isEnabled)
    #expect(try attachment.startIfEnabled(environment: ["TCA_HARNESS": "1", "TCA_HARNESS_PORT": "8768"]) == false)
    #expect(throws: (any Error).self) { try attachment.start(port: 8768) }
    await #expect(throws: (any Error).self) { try await attachment.runHeadless(port: 8768) }
    #endif
    #expect(attachment.server.status == "Stopped")
  }

  @Test func explicitAttachmentReportsConfigurationDiagnostics() async throws {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let descriptor = FeatureDescriptor<WorkspaceFeature.State, WorkspaceFeature.Action>("Invalid")
      .operation("same", action: .openButtonTapped)
      .operation("same", action: .closeButtonTapped)
    let attachment = store.harness(descriptor: descriptor)
    let response = try await Client(attachment.runtime.session).call("inspect")
    let diagnostics = response["diagnostics"] as? [String]
    #expect(diagnostics?.count == 1)
    #expect(diagnostics?.first?.contains("Duplicate operation") == true)
    #expect((response["features"] as? [[String: Any]])?.isEmpty == true)
    #expect(store.withState { $0.child } == nil)
  }

  @Test func generatedCollectionRoutesAndNestedArguments() async throws {
    let (store, runtime) = fixture()
    let client = Client(runtime.session)
    let inspection = try await client.call("inspect")
    #expect((inspection["features"] as! [[String: Any]]).count == 3)
    #expect(runtime.diagnostics.isEmpty)
    let snapshot = String(decoding: try JSONEncoder().encode(runtime.snapshot()), as: UTF8.self)
    #expect(!snapshot.contains("never-export-this"))
    #expect(!snapshot.contains("also-private"))
    let id = try client.id("root/items/2/rename@")
    let arguments: [String: Any] = ["title": "Second", "count": 7, "priority": "high", "detail": ["enabled": true, "tags": ["a", "b"]], "note": NSNull()]
    let response = try await client.dispatch(id, arguments: arguments)
    #expect(response["ok"] as? Bool == true)
    #expect(store.withState { $0.items[id: 2]?.title } == "Second")
    #expect(store.withState { $0.items[id: 1]?.title } == "")
    let bad = try await client.dispatch(id, arguments: ["title": "Invalid", "count": "seven", "priority": "high", "detail": ["enabled": true, "tags": []], "note": NSNull()])
    #expect(bad["error"] as? String == "invalid_arguments")
    #expect(store.withState { $0.items[id: 2]?.count } == 7)
    let priority = try client.id("root/items/2/priority@")
    let setPriority = try await client.dispatch(priority, arguments: ["value": "high"])
    #expect(setPriority["ok"] as? Bool == true)
    let invalidPriority = try await client.dispatch(priority, arguments: ["value": "unknown"])
    #expect(invalidPriority["error"] as? String == "invalid_arguments")
    #expect(store.withState { $0.items[id: 2]?.title } == "high")
  }

  @Test func optionalReplacementInvalidatesOperationsEvenWithoutObservedAbsence() async throws {
    let (store, runtime) = fixture()
    let client = Client(runtime.session)
    _ = try await client.call("observe")
    _ = try await client.dispatch(client.id("root/openButtonTapped@"))
    let old = try client.id("root/child/incrementButtonTapped@")
    store.send(.closeButtonTapped)
    store.send(.openButtonTapped)
    _ = try await client.call("observe")
    let fresh = try client.id("root/child/incrementButtonTapped@")
    #expect(old != fresh)
    let rejected = try await client.dispatch(old)
    #expect(rejected["error"] as? String == "unavailable_candidate")
    let accepted = try await client.dispatch(fresh)
    #expect(accepted["ok"] as? Bool == true)
    #expect(store.withState { $0.child?.count } == 1)
  }

  @Test func stackRoutesTargetTheCorrectEntry() async throws {
    var state = WorkspaceFeature.State()
    state.path.append(.init(id: 10)); state.path.append(.init(id: 11))
    let store = Store(initialState: state) { WorkspaceFeature() }
    let runtime = HarnessRuntime(descriptor: WorkspaceFeature.harnessDescriptor, read: { store.withState { $0 } }, send: { store.send($0) })
    let client = Client(runtime.session)
    let inspection = try await client.call("inspect")
    let nodes = inspection["features"] as! [[String: Any]]
    let stackNodes = nodes.filter { ($0["path"] as! String).hasPrefix("root/path/") }
    #expect(stackNodes.count == 2)
    let firstOperation = (stackNodes[0]["operations"] as! [[String: Any]]).first { ($0["id"] as! String).contains("incrementButtonTapped") }!["id"] as! String
    let result = try await client.dispatch(firstOperation)
    #expect(result["ok"] as? Bool == true)
    #expect(store.withState { Array($0.path).map(\.count) } == [1, 0])
  }

  @Test func completionCancellationAndRequestDeduplication() async throws {
    let (store, runtime) = fixture()
    let client = Client(runtime.session)
    _ = try await client.call("observe")
    let id = try client.id("root/save@")
    let revision = client.observation["revision"]!
    let result = try await client.dispatch(id, requestID: "save-1")
    #expect((result["receipt"] as? [String: Any])?["status"] as? String == "running")
    let duplicate = try await client.call("dispatch", ["candidateID": id, "revision": revision, "requestID": "save-1", "arguments": [:]])
    #expect(duplicate["ok"] as? Bool == true)
    store.send(.saveResponse)
    let done = try await client.call("wait", ["requestID": "save-1", "timeoutMs": 10])
    #expect((done["receipt"] as? [String: Any])?["status"] as? String == "succeeded")
    _ = try await client.dispatch(client.id("root/save@"), requestID: "save-2")
    let cancelled = try await client.call("cancel", ["requestID": "save-2"])
    #expect((cancelled["receipt"] as? [String: Any])?["status"] as? String == "cancelled")
    #expect(store.withState { $0.isSaving } == false)
  }

  @Test func operationsCanBuildTheirActionFromCurrentState() async throws {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let descriptor = FeatureDescriptor<WorkspaceFeature.State, WorkspaceFeature.Action>("Workspace")
      .operation("bumpLast", label: "Increment the last item", available: { !$0.items.isEmpty }) { state in
        .items(.element(id: state.items.ids.last!, action: .incrementButtonTapped))
      }
    let attachment = store.harness(descriptor: descriptor, timeline: nil)
    let client = Client(attachment.runtime.session)
    _ = try await client.call("observe")
    let response = try await client.dispatch(client.id("root/bumpLast@"))
    #expect(response["ok"] as? Bool == true)
    #expect(store.withState { $0.items.map(\.count) } == [0, 1])
  }

  @Test func duplicateOperationsFailClosed() {
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let descriptor = FeatureDescriptor<WorkspaceFeature.State, WorkspaceFeature.Action>("Invalid")
      .operation("same", action: .openButtonTapped)
      .operation("same", action: .closeButtonTapped)
    let runtime = HarnessRuntime(descriptor: descriptor, read: { store.withState { $0 } }, send: { store.send($0) })
    #expect(runtime.offers().isEmpty)
    #expect(runtime.diagnostics.count == 1)
  }

  @Test func removalCancelsAnOutstandingChildOperation() async throws {
    let store = Store(initialState: WorkspaceFeature.State(child: .init(id: 4))) { WorkspaceFeature() }
    let child = ItemFeature.harnessDescriptor.operation("watch", action: .incrementButtonTapped, completion: { _ in .running })
    let descriptor = FeatureDescriptor<WorkspaceFeature.State, WorkspaceFeature.Action>("Workspace")
      .optional("child", state: \.child, action: \.child, descriptor: child)
    let runtime = HarnessRuntime(descriptor: descriptor, read: { store.withState { $0 } }, send: { store.send($0) })
    let client = Client(runtime.session)
    _ = try await client.call("observe")
    _ = try await client.dispatch(client.id("root/child/watch@"), requestID: "watch")
    store.send(.closeButtonTapped)
    let response = try await client.call("wait", ["requestID": "watch", "timeoutMs": 10])
    #expect((response["receipt"] as? [String: Any])?["status"] as? String == "cancelled")
  }

  @Test func explicitScopeSupportsDifferentNamesAndPrivateProjection() async throws {
    let store = Store(initialState: WorkspaceFeature.State(child: .init(id: 4))) { WorkspaceFeature() }
    let descriptor = FeatureDescriptor<WorkspaceFeature.State, WorkspaceFeature.Action>("Workspace", observation: { _ in .object(["public": .bool(true)]) })
      .child("editor", state: { $0.child }, action: WorkspaceFeature.Action.child, descriptor: ItemFeature.harnessDescriptor)
    let runtime = HarnessRuntime(descriptor: descriptor, read: { store.withState { $0 } }, send: { store.send($0) })
    let client = Client(runtime.session)
    _ = try await client.call("observe")
    #expect((client.observation["state"] as? [String: Any])?["opaque"] == nil)
    _ = try await client.dispatch(client.id("root/editor/incrementButtonTapped@"))
    #expect(store.withState { $0.child?.count } == 1)
  }

  private func entries(_ timeline: HarnessTimeline) -> [HarnessTimelineEntry] {
    (timeline.page(since: 0, limit: 500)?.entries ?? []).sorted { $0.index < $1.index }
  }

  @Test(.timelineRecords) func timelineRecordsSourcesCausesEffectsAndMounts() async throws {
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: TimelineFeature.State()) { TimelineFeature().harnessTimeline(timeline) }
    let attachment = store.harness(TimelineFeature.self, timeline: timeline)
    let client = Client(attachment.runtime.session)
    store.send(.items(.element(id: 1, action: .incrementButtonTapped)))
    _ = try await client.call("observe")
    _ = try await client.dispatch(client.id("root/incrementButtonTapped@"))
    await store.send(.save).finish()

    let response = try await client.call("timeline", ["since": 0])
    let page = response["timeline"] as! [String: Any]
    #expect(page["detail"] as? String == "projected")
    let entries = (page["entries"] as! [[String: Any]]).sorted { ($0["index"] as! Int) < ($1["index"] as! Int) }
    #expect(entries.map { $0["action"] as! [String] } == [["items", "[1]", "incrementButtonTapped"], ["incrementButtonTapped"], ["save"], ["saveResponse"]])
    #expect(entries.map { $0["source"] as! String } == ["app", "agent", "app", "effect"])
    #expect((entries[1]["candidateID"] as? String)?.hasPrefix("root/incrementButtonTapped@") == true)
    #expect(entries[3]["cause"] as? Int == entries[2]["index"] as? Int)
    #expect((entries[2]["effect"] as? [String: Any])?["status"] as? String == "ended")
    #expect(entries[0]["effect"] == nil)
    #expect(entries[0]["changes"] as? [String] == ["items[0].count"])
    #expect(entries[1]["changes"] as? [String] == ["count"])
    #expect(entries.allSatisfy { $0["truncated"] as? Bool == false && ($0["recordMs"] as? Double ?? -1) >= 0 })
    let mounts = entries[1]["mounts"] as? [[String: Any]]
    #expect(mounts?.map { $0["path"] as! String } == ["root", "root/items/1"])
    let later = timeline.page(since: page["sequence"] as! Int)
    #expect(later?.entries.isEmpty == true && later?.hasMore == false)
  }

  @Test(.timelineRecords) func projectedTimelineHonorsExclusionsAndHidesPayloadValues() throws {
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: TimelineFeature.State()) { TimelineFeature().harnessTimeline(timeline) }
    let attachment = store.harness(TimelineFeature.self, timeline: timeline)
    store.send(.titleChanged("typed-secret"))
    store.send(.items(.element(id: 1, action: .rename(RenameInput(title: "nested-secret", count: 3,
      priority: .urgent, detail: DetailInput(enabled: true, tags: ["tag-secret"]), note: nil)))))
    let recorded = entries(timeline)
    #expect(recorded[0].payload == .object(["case": .string("titleChanged"), "value": .string("<String>")]))
    store.send(.tagged(["case": "dictionary-secret"]))
    #expect(entries(timeline)[2].payload == .object(["case": .string("tagged"), "value": .string("<Dictionary<String, String>>")]))
    store.send(.mode(.quiet))
    #expect(entries(timeline)[3].action == ["mode", "<DescribedMode>"])
    #expect(entries(timeline)[3].payload == .object(["case": .string("mode"), "value": .object(["case": .string("<DescribedMode>")])]))
    let payloads = String(decoding: try JSONEncoder().encode(entries(timeline).map(\.payload)), as: UTF8.self)
    for value in ["typed-secret", "nested-secret", "tag-secret", "dictionary-secret", "described-secret"] { #expect(!payloads.contains(value), "\(value) in payload") }
    let encoded = String(decoding: try JSONEncoder().encode(timeline.page(since: 0)), as: UTF8.self)
    for hidden in ["never-export-this", "also-private", "privateNotes"] { #expect(!encoded.contains(hidden), "\(hidden) leaked") }
    // State the descriptor observes stays visible; only payload values are hidden.
    #expect(recorded[0].changes == ["title"])
    _ = attachment
  }

  @Test(.timelineRecords) func reflectedTimelineShowsValuesButRedactsCredentials() throws {
    let timeline = HarnessTimeline(detail: .reflected, isEnabled: true)
    let store = Store(initialState: TimelineFeature.State()) { TimelineFeature().harnessTimeline(timeline) }
    store.send(.titleChanged("typed-value"))
    let page = try #require(timeline.page(since: 0))
    #expect(page.detail == "reflected")
    #expect(page.entries[0].payload == .object(["case": .string("titleChanged"), "value": .string("typed-value")]))
    let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
    #expect(!encoded.contains("never-export-this"))
    #expect(encoded.contains("also-private"))
  }

  @Test(.timelineRecords) func snapshotsAreDeferredUntilAPageIsServed() throws {
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: TimelineFeature.State()) { TimelineFeature().harnessTimeline(timeline) }
    var observations = 0
    let descriptor = FeatureDescriptor<TimelineFeature.State, TimelineFeature.Action>("Timeline", observation: { state in
      observations += 1
      return .object(["count": .number(Double(state.count))])
    })
    let attachment = store.harness(descriptor: descriptor, timeline: timeline)
    for _ in 0..<3 { store.send(.incrementButtonTapped) }
    #expect(observations == 0)
    let page = try #require(timeline.page(since: 0))
    #expect(page.entries.map(\.changes) == [["count"], ["count"], ["count"]])
    #expect(page.entries.map(\.state) == [1, 2, 3].map { .object(["count": .number($0)]) })
    // One snapshot per entry plus the state before the first one; served entries are not recomputed.
    #expect(observations == 4)
    _ = timeline.page(since: 0)
    #expect(observations == 4)
    _ = attachment
  }

  @Test(.timelineRecords) func effectActionsMatchByValueNotJustCaseName() {
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: TimelineFeature.State()) { TimelineFeature().harnessTimeline(timeline) }
    // An effect is about to send response(1); the user sends response(2) first.
    timeline.noteEffectAction(TimelineFeature.Action.response(1), cause: 99)
    store.send(.response(2))
    store.send(.response(1))
    let recorded = entries(timeline)
    #expect(recorded.map(\.source) == ["app", "effect"])
    #expect(recorded.map(\.cause) == [nil, 99])
  }

  @Test(.timelineRecords) func actionPathsDescendThroughCollectionsAndStacks() {
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature().harnessTimeline(timeline) }
    store.send(.path(.push(id: 0, state: .init(id: 5))))
    store.send(.path(.element(id: 0, action: .incrementButtonTapped)))
    store.send(.items(.element(id: 2, action: .priority(.urgent))))
    store.send(.closeButtonTapped)
    let paths = entries(timeline).map(\.action)
    #expect(paths[0] == ["path", "push"])
    #expect(paths[1].count == 3 && paths[1].first == "path" && paths[1].last == "incrementButtonTapped")
    #expect(paths[2] == ["items", "[2]", "priority", "urgent"])
    #expect(paths[3] == ["closeButtonTapped"])
  }

  @Test(.timelineRecords) func timelineIsUnavailableUntilAReducerRecordsAndInertWhenDisabled() async throws {
    let unattached = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: TimelineFeature.State()) { TimelineFeature() }
    let attachment = store.harness(TimelineFeature.self, timeline: unattached)
    let response = try await Client(attachment.runtime.session).call("timeline", ["since": 0])
    #expect(response["error"] as? String == "timeline_unavailable")

    let disabled = HarnessTimeline(isEnabled: false)
    let plain = Store(initialState: TimelineFeature.State()) { TimelineFeature().harnessTimeline(disabled) }
    plain.send(.incrementButtonTapped)
    #expect(disabled.page(since: 0) == nil)
    #expect(plain.withState { $0.count } == 1)

    let bounded = HarnessTimeline(capacity: 3, detail: .reflected, isEnabled: true)
    let counter = Store(initialState: TimelineFeature.State()) { TimelineFeature().harnessTimeline(bounded) }
    for _ in 0..<5 { counter.send(.incrementButtonTapped) }
    let first = try #require(bounded.page(since: 0, limit: 2))
    #expect(first.dropped == 2 && first.hasMore)
    #expect(first.entries.map(\.index) == [2, 3])
    let rest = try #require(bounded.page(since: first.sequence, limit: 2))
    #expect(rest.entries.map(\.index) == [4] && !rest.hasMore)
    #expect(counter.withState { $0.count } == 5)
  }
}

extension Trait where Self == ConditionTrait {
  /// Timelines are inert in builds compiled without `DEBUG`.
  static var timelineRecords: Self { .enabled(if: HarnessServer.isAvailable, "Timelines record only in DEBUG builds") }
}

/// Blocking newline-JSON client over a real TCP socket, for headless-host tests. Use off the main actor.
private final class LineSocket: @unchecked Sendable {
  private let descriptor: Int32
  private var buffer = Data()

  init(port: UInt16) throws {
    descriptor = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { close(descriptor); throw HarnessArgumentError("connect failed: \(errno)") }
  }

  deinit { close(descriptor) }

  func call(_ request: [String: Any]) throws -> [String: Any] {
    var line = try JSONSerialization.data(withJSONObject: request)
    line.append(10)
    _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !buffer.contains(10) {
      let count = read(descriptor, &chunk, chunk.count)
      guard count > 0 else { throw HarnessArgumentError("connection closed") }
      buffer.append(contentsOf: chunk[..<count])
    }
    let newline = buffer.firstIndex(of: 10)!
    let response = buffer[..<newline]
    buffer.removeSubrange(...newline)
    return try JSONSerialization.jsonObject(with: response) as! [String: Any]
  }
}
