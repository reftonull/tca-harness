import ComposableArchitecture
import Foundation
import TCAHarnessTCA2
import Testing

/// Drives a harness the way the CLI does: JSON in, JSON out.
@MainActor
final class Client {
  let session: HarnessSession<HarnessValue>
  var observation: [String: Any] = [:]
  private var requests = 0

  init(_ runtime: HarnessRuntime<some Any, some Any>) { session = runtime.session }

  @discardableResult
  func call(_ request: [String: Any]) async -> [String: Any] {
    var request = request
    if request["sessionID"] == nil, let id = observation["sessionID"] { request["sessionID"] = id }
    let data = await session.handleJSON(try! JSONSerialization.data(withJSONObject: request))
    let response = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    if let observation = response["observation"] as? [String: Any] { self.observation = observation }
    return response
  }

  @discardableResult func observe() async -> [String: Any] { await call(["method": "observe"]) }

  var state: [String: Any] { observation["state"] as! [String: Any] }
  var candidates: [String] { (observation["candidates"] as! [[String: Any]]).map { $0["id"] as! String } }

  func candidate(_ prefix: String) -> String? {
    candidates.first { $0.hasPrefix(prefix + "@") }
  }

  @discardableResult
  func dispatch(_ prefix: String, _ arguments: [String: Any] = [:], requestID: String? = nil) async -> [String: Any] {
    if observation.isEmpty { await observe() }
    guard let id = candidate(prefix) else {
      Issue.record("No candidate \(prefix) in \(candidates)")
      return [:]
    }
    requests += 1
    return await call(["method": "dispatch", "candidateID": id, "revision": observation["revision"]!,
      "requestID": requestID ?? "request-\(requests)", "arguments": arguments])
  }

  func wait(_ response: [String: Any]) async -> [String: Any] {
    let receipt = response["receipt"] as! [String: Any]
    return await call(["method": "wait", "requestID": receipt["requestID"]!, "timeoutMs": 3000])
  }
}

func status(_ response: [String: Any]) -> String? { (response["receipt"] as? [String: Any])?["status"] as? String }

@MainActor
@Suite struct RuntimeTests {
  let store = Store(initialState: Workspace.State()) { Workspace() }

  func client(verify: @escaping (Workspace.State, String) -> Bool? = { _, _ in nil }) -> (StoreHarness<Workspace.State, Workspace.Action>, Client) {
    let harness = store.harness(Workspace.self, verify: verify)
    return (harness, Client(harness.runtime))
  }

  @Test func observationComposesChildrenAndRedacts() async throws {
    let (harness, client) = client()
    _ = harness
    await client.observe()
    let state = client.state
    #expect(state["password"] as? String == "<redacted>")
    #expect(state["privateNotes"] == nil)
    #expect((state["counter"] as? [String: Any])?["count"] as? Double == 0)
    #expect((state["items"] as? [[String: Any]])?.count == 2)
    #expect(state["archive"] is NSNull)
    #expect(state["priority"] as? String == "normal")
    #expect((state["refresh"] as? [String: Any])?["isRunning"] as? Bool == false)
    #expect((state["opaque"] as? String)?.hasPrefix("<opaque") == true || state["opaque"] is [String: Any])
    let candidates = client.candidates
    #expect(client.candidate("root/counter/incrementButtonTapped") != nil)
    #expect(client.candidate("root/items/1/incrementButtonTapped") != nil)
    #expect(client.candidate("root/items/2/incrementButtonTapped") != nil)
    #expect(client.candidate("root/removeItem/1") != nil)
    #expect(client.candidate("root/openArchiveTapped") != nil)
    #expect(!candidates.contains { $0.contains("refreshResponse") })
    let inspection = await client.call(["method": "inspect"])
    #expect(inspection["diagnostics"] as? [String] == [])
  }

  @Test func scopedAndCollectionChildrenReceiveActions() async throws {
    let (harness, client) = client()
    _ = harness
    #expect(await client.dispatch("root/counter/incrementButtonTapped")["ok"] as? Bool == true)
    #expect(store.counter.count == 1)
    #expect(await client.dispatch("root/items/2/incrementButtonTapped")["ok"] as? Bool == true)
    #expect(store.items.map(\.count) == [0, 1])
    let removed = await client.dispatch("root/removeItem/1")
    #expect(status(removed) == "succeeded")
    #expect(store.items.map(\.id) == [2])
    #expect(client.candidate("root/items/1/incrementButtonTapped") == nil)
    let renamed = await client.dispatch("root/renameItem/2", ["value": "Renamed"])
    #expect(renamed["ok"] as? Bool == true)
    #expect(store.items.first?.title == "Renamed")
  }

  @Test func bindingsWriteThroughTheStore() async throws {
    let (harness, client) = client()
    _ = harness
    #expect(await client.dispatch("root/title", ["value": "Launch plan"])["ok"] as? Bool == true)
    #expect(store.title == "Launch plan")
    // String enums and Bools get one argument-free candidate per other value.
    #expect(client.candidate("root/priority/normal") == nil)
    #expect(await client.dispatch("root/priority/high")["ok"] as? Bool == true)
    #expect(store.priority == .high)
    #expect(client.candidate("root/priority/high") == nil)
    #expect(client.candidate("root/priority/low") != nil)
    #expect(client.state["title"] as? String == "Launch plan")
  }

  @Test func typedArgumentsValidateBeforeDispatch() async throws {
    let (harness, client) = client()
    _ = harness
    let blank = await client.dispatch("root/addDraft", ["title": "  ", "priority": "low", "tags": [], "note": NSNull()])
    #expect(blank["error"] as? String == "invalid_arguments")
    #expect((blank["detail"] as? String)?.contains("blank") == true)
    let long = await client.dispatch("root/addDraft", ["title": String(repeating: "x", count: 41), "priority": "low", "tags": [], "note": NSNull()])
    #expect(long["error"] as? String == "invalid_arguments")
    #expect(store.drafts.isEmpty)
    let valid = await client.dispatch("root/addDraft", ["title": "Ship", "priority": "high", "tags": ["a"], "note": "n"])
    #expect(valid["ok"] as? Bool == true)
    #expect(store.drafts == ["Ship"])
    let schema = (client.observation["candidates"] as! [[String: Any]]).first { ($0["id"] as! String).hasPrefix("root/addDraft@") }?["argumentSchema"] as? [String: Any]
    let title = (schema?["properties"] as? [String: Any])?["title"] as? [String: Any]
    #expect(title?["maxLength"] as? Int == 40)
    #expect(title?["description"] as? String == "Item title")
  }

  @Test func enumDestinationsMountTheirCurrentCase() async throws {
    let (harness, client) = client()
    _ = harness
    await client.dispatch("root/editButtonTapped")
    #expect(client.candidate("root/destination/editor/saveButtonTapped") != nil)
    #expect(client.candidate("root/destination/alert/confirmTapped") == nil)
    let destination = client.state["destination"] as? [String: Any]
    #expect(destination?["case"] as? String == "editor")
    #expect(await client.dispatch("root/destination/editor/name", ["value": "Draft"])["ok"] as? Bool == true)
    guard case let .editor(editor)? = store.destination else { Issue.record("Editor not presented"); return }
    #expect(editor.name == "Draft")

    let save = await client.dispatch("root/destination/editor/saveButtonTapped")
    #expect(status(save) == "running")
    let finished = await client.wait(save)
    #expect(status(finished) == "succeeded")
    guard case let .editor(saved)? = store.destination else { Issue.record("Editor dismissed"); return }
    #expect(saved.saved)

    // A self-dismissing action marked `.dispatch` succeeds even though its feature disappears.
    let close = await client.dispatch("root/destination/editor/closeButtonTapped")
    #expect(status(close) == "succeeded")
    try await Task.sleep(for: .milliseconds(50))
    #expect(store.destination == nil)

    await client.dispatch("root/alertButtonTapped")
    #expect(await client.dispatch("root/destination/alert/confirmTapped")["ok"] as? Bool == true)
    #expect(store.destination == nil)
  }

  @Test func spawnedChildEffectsCompleteOrCancelOnDismount() async throws {
    let (harness, client) = client()
    _ = harness
    await client.dispatch("root/openArchiveTapped")
    #expect(client.candidate("root/openArchiveTapped") == nil)  // availability key path
    let firstSave = client.candidate("root/archive/saveButtonTapped")!
    let save = await client.dispatch("root/archive/saveButtonTapped")
    #expect(status(save) == "running")
    let short = await client.call(["method": "wait", "requestID": (save["receipt"] as! [String: Any])["requestID"]!, "timeoutMs": 1])
    #expect(short["error"] as? String == "wait_timeout")
    #expect(status(await client.wait(save)) == "succeeded")
    #expect(store.archive?.saved == true)

    await client.dispatch("root/closeArchiveButtonTapped")
    await client.dispatch("root/openArchiveTapped")
    // The re-spawned child is a new store, so the old candidate cannot reach it.
    #expect(client.candidate("root/archive/saveButtonTapped") != firstSave)
    let stale = await client.call(["method": "dispatch", "candidateID": firstSave, "revision": client.observation["revision"]!, "requestID": "stale"])
    #expect(stale["error"] as? String == "unavailable_candidate")

    let pending = await client.dispatch("root/archive/saveButtonTapped")
    #expect(status(pending) == "running")
    await client.dispatch("root/closeArchiveButtonTapped")
    #expect(status(await client.wait(pending)) == "cancelled")
  }

  @Test func explicitCancellationCancelsTheActionsTasks() async throws {
    let (harness, client) = client()
    _ = harness
    await client.dispatch("root/openArchiveTapped")
    let save = await client.dispatch("root/archive/saveButtonTapped")
    let requestID = (save["receipt"] as! [String: Any])["requestID"]!
    let cancelled = await client.call(["method": "cancel", "requestID": requestID])
    #expect(status(cancelled) == "cancelled")
    try await Task.sleep(for: .milliseconds(250))
    #expect(store.archive?.saved == false)
  }

  @Test func spawnedArraysWithoutIdentifiableStateRouteByIndex() async throws {
    let (harness, client) = client()
    _ = harness
    await client.dispatch("root/addNoteButtonTapped")
    await client.dispatch("root/addNoteButtonTapped")
    #expect(await client.dispatch("root/notes/1/pinButtonTapped")["ok"] as? Bool == true)
    #expect(store.notes.map(\.pinned) == [false, true])
    #expect((client.state["notes"] as? [[String: Any]])?.compactMap { $0["pinned"] as? Bool } == [false, true])
  }

  @Test func stackPathsMountEachElement() async throws {
    let (harness, client) = client()
    _ = harness
    await client.dispatch("root/pushItemButtonTapped")
    await client.dispatch("root/pushItemButtonTapped")
    let paths = client.candidates.filter { $0.hasPrefix("root/path/") }
    #expect(paths.count == 2)
    // Stack IDs are opaque, so elements are routed by position and resolved by ID.
    #expect(client.candidate("root/path/0/item/incrementButtonTapped") != nil)
    #expect(client.candidate("root/path/1/item/incrementButtonTapped") != nil)
    let first = try #require(paths.sorted().first)
    let response = await client.call(["method": "dispatch", "candidateID": first, "revision": client.observation["revision"]!, "requestID": "push"])
    #expect(response["ok"] as? Bool == true)
    let counts = store.path.compactMap { state -> Int? in
      if case let .item(item) = state { return item.count } else { return nil }
    }
    #expect(counts.sorted() == [0, 1])
  }

  @Test func observeVerifyAndDeduplicate() async throws {
    let (harness, client) = client { state, condition in
      condition == "titled" ? !state.title.isEmpty : nil
    }
    _ = harness
    #expect(await client.call(["method": "verify", "condition": "titled"])["verified"] as? Bool == false)
    let candidate = client.candidate("root/counter/incrementButtonTapped")!
    let revision = client.observation["revision"] as! Int
    let request: [String: Any] = ["method": "dispatch", "candidateID": candidate, "revision": revision, "requestID": "once"]
    #expect(await client.call(request)["ok"] as? Bool == true)
    let retry = await client.call(request)
    #expect(retry["ok"] as? Bool == true)
    #expect(store.counter.count == 1)  // A matching retry returns the first receipt without dispatching again.
    var conflicting = request; conflicting["arguments"] = ["unexpected": true]
    #expect(await client.call(conflicting)["error"] as? String == "request_id_conflict")
    var stale = request; stale["requestID"] = "twice"
    #expect(await client.call(stale)["error"] as? String == "stale_revision")
    #expect(store.counter.count == 1)
    await client.dispatch("root/title", ["value": "Done"])
    #expect(await client.call(["method": "verify", "condition": "titled"])["verified"] as? Bool == true)
    #expect(await client.call(["method": "verify", "condition": "unknown"])["error"] as? String == "unknown_verification_condition")
  }

  @Test func customizationTypoFailsClosed() async throws {
    let descriptor = Workspace.harnessDescriptor.available("doesNotExist") { _ in true }
    let harness = store.harness(descriptor: descriptor)
    let client = Client(harness.runtime)
    let inspection = await client.call(["method": "inspect"])
    #expect((inspection["diagnostics"] as? [String])?.first?.contains("doesNotExist") == true)
    await client.observe()
    #expect(client.candidates.isEmpty)
  }

  @Test func startIfEnabledRespectsEnvironment() throws {
    let (harness, _) = client()
    #expect(try harness.startIfEnabled(environment: [:]) == false)
    if HarnessServer.isAvailable {
      #expect(throws: HarnessArgumentError.self) { try harness.startIfEnabled(environment: ["TCA_HARNESS": "1", "TCA_HARNESS_PORT": "0"]) }
    } else {
      // Release builds compile the listener out and never read the environment.
      #expect(try harness.startIfEnabled(environment: ["TCA_HARNESS": "1", "TCA_HARNESS_PORT": "0"]) == false)
    }
  }
}

