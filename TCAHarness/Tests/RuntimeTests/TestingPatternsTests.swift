import ComposableArchitecture
import Foundation
import IssueReporting
import Network
@testable import TCAHarness
import Testing

// MARK: Fixtures

@HarnessFeature
@Reducer
struct BookList {
  @ObservableState
  struct State {
    var books: [String] = []
  }
  enum Action {
    case addButtonTapped
    case loadButtonTapped
  }
  @Dependency(\.uuid) var uuid
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .addButtonTapped: state.books.append("Dune")
      case .loadButtonTapped: state.books.append(uuid().uuidString)
      }
      return .none
    }
  }
}

// What `@HarnessFeature` users write to add invariants.
extension BookList {
  @MainActor static func customizeHarnessDescriptor(_ descriptor: FeatureDescriptor<State, Action>) -> FeatureDescriptor<State, Action> {
    descriptor.invariant("no duplicate books") { Set($0.books).count == $0.books.count }
  }
}

@HarnessFeature
@Reducer
struct Library {
  @ObservableState
  struct State {
    var shelf: BookList.State = .init()
  }
  enum Action {
    case shelf(BookList.Action)
  }
  var body: some ReducerOf<Self> {
    Scope(state: \.shelf, action: \.shelf) { BookList() }
  }
}

private func json(_ data: Data) -> [String: Any] {
  (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// MARK: Issues and invariants

@Suite @MainActor
struct IssueAndInvariantTests {
  /// TCA's own runtime warnings reach the log from a real Store (not a TestStore). The reporters
  /// are scoped to an empty list so the test checks capture instead of failing on the issue.
  @Test(.enabled(if: HarnessServer.isAvailable, "Issue capture is installed only in DEBUG builds"))
  func runtimeWarningsFromARealStoreAreCaptured() throws {
    let log = HarnessIssueLog()
    let timeline = HarnessTimeline(isEnabled: true)
    withIssueReporters([]) {
      let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature().harnessTimeline(timeline) }
      var attachment: StoreHarness? = store.harness(WorkspaceFeature.self, timeline: timeline, issues: log)
      #expect(IssueReporters.current.contains { $0 is HarnessIssueReporter })
      // A second attachment on the same log must not duplicate entries.
      let second = store.harness(WorkspaceFeature.self, timeline: timeline, issues: log)

      // The child is nil: TCA's `ifLet` reports a runtime warning.
      store.send(.child(.incrementButtonTapped))
      // An `unimplemented` dependency reports through the same channel.
      let library = Store(initialState: BookList.State()) { BookList().harnessTimeline(timeline) } withDependencies: {
        $0.uuid = UUIDGenerator(unimplemented("BookList.uuid", placeholder: UUID()))
      }
      library.send(.loadButtonTapped)
      report("Custom issue")

      let issues = log.issues()
      #expect(issues.count == 3)
      #expect(issues.map(\.kind) == ["issue", "issue", "issue"])
      #expect(issues[0].message.contains("ifLet"))
      #expect(issues[0].action == "child.incrementButtonTapped")
      #expect(issues[0].file?.hasSuffix(".swift") == true && issues[0].file?.contains("/") == false)
      #expect(issues[0].line != nil)
      #expect(issues[1].message.contains("BookList.uuid"))
      #expect(issues[1].action == "loadButtonTapped")
      #expect(issues[2].message == "Custom issue")
      #expect(issues[2].file == "TestingPatternsTests.swift")

      // Releasing an attachment removes its reporter; the other one takes over.
      attachment = nil
      _ = attachment
      #expect(IssueReporters.current.compactMap { $0 as? HarnessIssueReporter }.filter { $0.log === log }.count == 1)
      report("After release")
      #expect(log.count == 4)
      withExtendedLifetime(second) {}
    }
  }

  @Test func invariantsArePrefixedAndLoggedOnlyWhenTheyBecomeViolated() async throws {
    let log = HarnessIssueLog()
    let item = ItemFeature.harnessDescriptor.invariant("count is small") { $0.count < 2 }
    let descriptor = FeatureDescriptor<WorkspaceFeature.State, WorkspaceFeature.Action>("Workspace")
      .operation("openButtonTapped", action: .openButtonTapped)
      .invariant("not saving") { !$0.isSaving }
      .optional("editor", state: \.child, action: \.child, descriptor: item)
      .identified("items", state: \.items, action: \.items, descriptor: item)
    let names = descriptor.evaluateInvariants(WorkspaceFeature.State()).map(\.name)
    #expect(names == ["root: not saving", "root/items/1: count is small", "root/items/2: count is small"])

    let store = Store(initialState: WorkspaceFeature.State()) { WorkspaceFeature() }
    let attachment = store.harness(descriptor: descriptor, timeline: nil, issues: log)
    let client = Client(attachment.runtime.session)
    _ = try await client.call("observe")
    #expect(log.count == 0)

    // Without a timeline, invariants are checked when the session observes.
    store.send(.items(.element(id: 1, action: .incrementButtonTapped)))
    store.send(.items(.element(id: 1, action: .incrementButtonTapped)))
    #expect(log.count == 0)
    var response = try await client.call("observe")
    #expect((response["observation"] as? [String: Any])?["issueCount"] as? Int == 1)
    #expect(log.issues().map(\.message) == ["root/items/1: count is small"])
    #expect(log.issues().first?.kind == "invariant")

    // Still violated: not logged again, however often it is observed.
    store.send(.items(.element(id: 1, action: .incrementButtonTapped)))
    _ = try await client.call("observe")
    _ = try await client.call("observe")
    #expect(log.count == 1)

    // Holds again, then breaks again: a second entry.
    store.send(.items(.element(id: 1, action: .rename(RenameInput(title: "", count: 0, priority: .normal,
      detail: DetailInput(enabled: false, tags: []), note: nil)))))
    _ = try await client.call("observe")
    store.send(.items(.element(id: 1, action: .incrementButtonTapped)))
    store.send(.items(.element(id: 1, action: .incrementButtonTapped)))
    // Dispatch observes too (it rejects the stale revision, and the failure still carries an observation).
    let stale = try await client.dispatch(client.id("root/openButtonTapped@"))
    #expect(stale["error"] as? String == "stale_revision")
    #expect(log.count == 2)
    _ = try await client.dispatch(client.id("root/openButtonTapped@"))
    #expect(log.issues().map(\.message) == ["root/items/1: count is small", "root/items/1: count is small"])

    // A mounted optional child is checked under its own path; element ids are route segments.
    store.send(.child(.incrementButtonTapped))
    store.send(.child(.incrementButtonTapped))
    response = try await client.call("issues", ["since": 2])
    let issues = response["issues"] as? [[String: Any]]
    #expect(issues?.map { $0["message"] as? String } == ["root/editor: count is small"])
    #expect(issues?.first?["seq"] as? Int == 3)
  }

  @Test(.timelineRecords) func invariantsAreCheckedAfterEveryReducedActionWithATimeline() throws {
    let log = HarnessIssueLog()
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: Library.State()) { Library().harnessTimeline(timeline) }
    let attachment = store.harness(Library.self, timeline: timeline, issues: log)
    store.send(.shelf(.addButtonTapped))
    #expect(log.count == 0)
    store.send(.shelf(.addButtonTapped))
    // Recorded inside the reducer pass, before anything observes; the macro hook added the invariant.
    #expect(log.issues().map(\.message) == ["root/shelf: no duplicate books"])
    #expect(log.issues().first?.action == "shelf.addButtonTapped")
    store.send(.shelf(.addButtonTapped))
    #expect(log.count == 1)
    _ = attachment
  }

  @Test func protocolVersionThreeAddsIssuesAndIssueCount() async throws {
    let log = HarnessIssueLog()
    let store = Store(initialState: Library.State()) { Library() }
    let attachment = store.harness(Library.self, timeline: nil, issues: log)
    let client = Client(attachment.runtime.session)
    let inspected = try await client.call("inspect")
    #expect(inspected["protocolVersion"] as? Int == 3)
    #expect((inspected["observation"] as? [String: Any])?["issueCount"] as? Int == 0)

    log.record(kind: "issue", message: "Something went wrong", file: "Sources/Shelf/Shelf.swift", line: 42, action: "shelf.deleteResponse")
    _ = try await client.dispatch(client.id("root/shelf/addButtonTapped@"))
    _ = try await client.dispatch(client.id("root/shelf/addButtonTapped@"))
    let raw = await attachment.runtime.session.handleJSON(Data(#"{"method":"issues","since":0}"#.utf8))
    print("PROTOCOL-EXAMPLE issues:", String(decoding: raw, as: UTF8.self))
    let response = json(raw)
    let issues = response["issues"] as! [[String: Any]]
    #expect(issues.count == 2)
    #expect(issues[0]["seq"] as? Int == 1)
    #expect(issues[0]["file"] as? String == "Shelf.swift")
    #expect(issues[0]["line"] as? Int == 42)
    #expect(issues[0]["action"] as? String == "shelf.deleteResponse")
    #expect(issues[1]["kind"] as? String == "invariant")
    #expect(issues[1]["message"] as? String == "root/shelf: no duplicate books")
    // Absent fields are explicit nulls.
    #expect(issues[1]["file"] is NSNull && issues[1]["action"] is NSNull)
    #expect((response["observation"] as? [String: Any])?["issueCount"] as? Int == 2)
    let later = try await client.call("issues", ["since": 2])
    #expect((later["issues"] as? [Any])?.isEmpty == true)
  }
}

// MARK: Deterministic dependencies

@Suite
struct DeterministicDependencyTests {
  struct Sample: Equatable {
    let uuids: [UUID]
    let now: Date
    let numbers: [Int]
  }

  private func sample(_ configure: (inout DependencyValues) -> Void) -> Sample {
    withDependencies(configure) {
      @Dependency(\.uuid) var uuid
      @Dependency(\.date) var date
      @Dependency(\.withRandomNumberGenerator) var random
      return Sample(uuids: [uuid(), uuid()], now: date.now,
        numbers: (0..<5).map { _ in random { Int.random(in: 0..<1_000_000, using: &$0) } })
    }
  }

  @Test func seededRunsRepeat() {
    let first = sample { $0.harnessDeterministic(seed: 42) }
    #expect(first == sample { $0.harnessDeterministic(seed: 42) })
    #expect(first.uuids == [UUID(0), UUID(1)])
    #expect(first.now == HarnessDeterministic.startDate)
    #expect(ISO8601DateFormatter().string(from: first.now) == "2026-01-01T00:00:00Z")
    #expect(first.numbers != sample { $0.harnessDeterministic(seed: 43) }.numbers)
  }

  @Test(.enabled(if: HarnessServer.isAvailable, "The environment is read only in DEBUG builds"))
  func environmentSeed() {
    #expect(sample { $0.harnessDeterministic(environment: ["TCA_HARNESS_SEED": "7"]) } == sample { $0.harnessDeterministic(seed: 7) })
    let fixed = Date(timeIntervalSince1970: 5)
    let untouched = withDependencies {
      $0.date = .constant(fixed)
      $0.harnessDeterministic(environment: [:])
    } operation: {
      @Dependency(\.date.now) var now
      return now
    }
    #expect(untouched == fixed)
  }

  @Test func generatorIsSplitMix64() {
    var generator = HarnessRandomNumberGenerator(seed: 0)
    // Reference values for SplitMix64 seeded with 0.
    #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
  }
}

// MARK: Network

/// One shared protocol class and state per process, so these run one at a time.
@Suite(.serialized, .enabled(if: HarnessNetwork.isAvailable, "Interception exists only in DEBUG builds")) @MainActor
struct HarnessNetworkTests {
  let session = URLSession(configuration: HarnessNetwork.configure(.ephemeral))
  let state = HarnessNetwork.shared
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-cassettes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    state.reset()
    state.cassettes = directory
  }

  private func write(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent(name))
  }

  private func request(_ method: String, _ url: String, body: String? = nil) async -> (status: Int?, body: String, error: URLError?) {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    if let body { request.httpBody = Data(body.utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    do {
      let (data, response) = try await session.data(for: request)
      return ((response as? HTTPURLResponse)?.statusCode, String(decoding: data, as: UTF8.self), nil)
    } catch {
      return (nil, "", error as? URLError)
    }
  }

  private func networkIssues(since: Int) -> [String] {
    HarnessIssueLog.shared.issues(since: since).filter { $0.kind == "network" }.map(\.message)
  }

  @Test func blockFailsEveryRequestAndReportsIt() async {
    state.mode = .block
    let before = HarnessIssueLog.shared.count
    let result = await request("GET", "http://api.invalid/books")
    #expect(result.error?.code == .notConnectedToInternet)
    #expect(state.requests().map(\.source) == ["blocked"])
    #expect(state.requests().first?.status == nil)
    #expect(networkIssues(since: before) == ["Blocked GET /books (network mode block)"])
  }

  @Test func replayMatchesByMethodPathQueryAndBody() async throws {
    state.mode = .replay
    try write("GET__books_1.json", #"{"request":{"method":"GET","url":"http://api/books","body":null},"response":{"status":200,"headers":{"Content-Type":"application/json"},"body":[{"title":"Dune"}]}}"#)
    try write("GET__books_2.json", #"{"request":{"method":"GET","url":"http://api/books","body":null},"response":{"status":200,"headers":{},"body":[{"title":"Dune"},{"title":"Emma"}]}}"#)
    try write("POST__books_1.json", #"{"request":{"method":"POST","url":"http://api/books","body":{"title":"Dune"}},"response":{"status":201,"headers":{},"body":{"id":1}}}"#)
    try write("POST__books_2.json", #"{"request":{"method":"POST","url":"http://api/books","body":{"title":"Emma"}},"response":{"status":201,"headers":{},"body":{"id":2}}}"#)
    try write("GET__search_1.json", #"{"request":{"method":"GET","url":"http://api/search?q=dune","body":null},"response":{"status":200,"headers":{},"body":"plain text"}}"#)

    // Equal recordings are served in order, then the last repeats.
    #expect(await request("GET", "http://api/books").body.contains("Emma") == false)
    #expect(await request("GET", "http://api/books").body.contains("Emma"))
    #expect(await request("GET", "http://api/books").body.contains("Emma"))
    // Body picks the recording; host is not part of the match.
    let emma = await request("POST", "http://other-host/books", body: #"{"title":"Emma"}"#)
    #expect(emma.status == 201 && emma.body == #"{"id":2}"#)
    // No exact match: the latest recording for the method and path.
    #expect(await request("POST", "http://api/books", body: #"{"title":"Zed"}"#).body == #"{"id":2}"#)
    #expect(await request("GET", "http://api/search?q=dune").body == "plain text")
    #expect(await request("GET", "http://api/search?q=other").body == "plain text")
    #expect(Set(state.requests().map(\.source)) == ["fixture"])

    let before = HarnessIssueLog.shared.count
    let missing = await request("DELETE", "http://api/books/1")
    #expect(missing.error?.code == .notConnectedToInternet)
    #expect(state.requests().last?.source == "blocked")
    #expect(networkIssues(since: before) == ["No fixture for DELETE /books/1"])
  }

  @Test func everyRequestSaysHowItWasAnswered() async throws {
    state.mode = .replay
    try write("GET__books_1.json", #"{"request":{"method":"GET","url":"http://api/books","body":null},"response":{"status":200,"headers":{},"body":[]}}"#)
    try write("GET__messages_1.json", #"{"request":{"method":"GET","url":"http://api/messages","body":null},"response":{"status":200,"headers":{},"body":[1]}}"#)
    try write("GET__messages_2.json", #"{"request":{"method":"GET","url":"http://api/messages","body":null},"response":{"status":200,"headers":{},"body":[1,2]}}"#)
    _ = await request("GET", "http://api/books")             // exact
    _ = await request("GET", "http://api/messages")          // ordered: first of two equal recordings
    _ = await request("GET", "http://api/messages")          // ordered: second
    _ = await request("GET", "http://api/books?page=2")      // path: query differs, latest for GET /books
    _ = await request("GET", "http://api/authors")           // blocked: no fixture
    state.faults = [HarnessFault(match: .init(path: "/books"), kind: .status, status: 500)]
    _ = await request("GET", "http://api/books")             // fault
    let log = state.requests()
    #expect(log.map(\.match) == ["exact", "ordered", "ordered", "path", "blocked", "fault"])
    #expect(log.map(\.cassette) == ["GET__books_1.json", "GET__messages_1.json", "GET__messages_2.json", "GET__books_1.json", nil, nil])
    let encoded = String(decoding: try JSONEncoder().encode(log[0]), as: UTF8.self)
    #expect(encoded.contains(#""match":"exact""#) && encoded.contains(#""cassette":"GET__books_1.json""#) && !encoded.contains("template"))
    #expect(try JSONDecoder().decode(HarnessNetworkRequest.self, from: Data(encoded.utf8)) == log[0])
    // Logs from older versions have no `match`.
    let old = #"{"seq":1,"method":"GET","url":"http://api/books","status":200,"source":"fixture","fault":null,"ms":1}"#
    #expect(try JSONDecoder().decode(HarnessNetworkRequest.self, from: Data(old.utf8)).match == nil)
  }

  @Test func matchRulesIgnoreQueryShareTemplatesAndEndPagination() async throws {
    state.mode = .replay
    try write("match.json", #"""
      {"ignore_query": ["t"],
       "path_templates": ["/users/{id}", "/rides/{id}/attendees"],
       "paths": {"/events": {"ignore_body": true}, "/rides": {"ignore_query": ["lat", "lon"]}},
       "pagination": [{"path": "/feed", "cursor": ["max_id", "page"]},
                      {"path": "/tags/{tag}", "cursor": "cursor", "terminal": {"status": 200, "body": {"items": [], "next": null}}}]}
      """#)
    try write("GET__users_123_1.json", #"{"request":{"method":"GET","url":"http://api/users/123","body":null},"response":{"status":200,"headers":{},"body":{"id":123}}}"#)
    try write("GET__rides_1.json", #"{"request":{"method":"GET","url":"http://api/rides?lat=52.5&lon=13.4&month=1&t=99","body":null},"response":{"status":200,"headers":{},"body":["ride"]}}"#)
    try write("GET__rides_7_attendees_1.json", #"{"request":{"method":"GET","url":"http://api/rides/7/attendees","body":null},"response":{"status":200,"headers":{},"body":["ann"]}}"#)
    try write("POST__events_1.json", #"{"request":{"method":"POST","url":"http://api/events","body":{"name":"search"}},"response":{"status":204,"headers":{},"body":null}}"#)
    try write("GET__feed_1.json", #"{"request":{"method":"GET","url":"http://api/feed?limit=40","body":null},"response":{"status":200,"headers":{},"body":[1,2]}}"#)
    try write("GET__feed_2.json", #"{"request":{"method":"GET","url":"http://api/feed?max_id=2&limit=40","body":null},"response":{"status":200,"headers":{},"body":[3]}}"#)

    // ignore_query: global `t`, and the location for /rides only. `month` still has to match.
    #expect(await request("GET", "http://api/rides?lat=48.1&lon=11.6&month=1&t=5").body == #"["ride"]"#)
    #expect(await request("GET", "http://api/rides?lat=48.1&lon=11.6&month=2").body == #"["ride"]"#)
    // path_templates: no cassette for /users/456 or /rides/9/attendees, so the template's cassette answers.
    #expect(await request("GET", "http://api/users/456").body == #"{"id":123}"#)
    #expect(await request("GET", "http://api/users/123").body == #"{"id":123}"#)
    #expect(await request("GET", "http://api/rides/9/attendees").body == #"["ann"]"#)
    #expect(await request("GET", "http://api/users/1/posts").error?.code == .notConnectedToInternet)
    // ignore_body
    #expect(await request("POST", "http://api/events", body: #"{"name":"open"}"#).status == 204)
    // pagination: recorded pages match; a later page with no cassette ends the feed instead of repeating.
    #expect(await request("GET", "http://api/feed?limit=40").body == "[1,2]")
    #expect(await request("GET", "http://api/feed?max_id=2&limit=40").body == "[3]")
    let end = await request("GET", "http://api/feed?max_id=3&limit=40")
    #expect(end.status == 200 && end.body == "[]")
    let tagEnd = json(Data(await request("GET", "http://api/tags/bikes?cursor=abc").body.utf8))
    #expect((tagEnd["items"] as? [Any])?.isEmpty == true && tagEnd["next"] is NSNull)
    // The first page (no cursor) without a match still falls back to the latest recording.
    #expect(await request("GET", "http://api/feed?limit=10").body == "[3]")

    let log = state.requests()
    #expect(log.map(\.match) == ["exact", "path", "template", "exact", "template", "blocked", "exact", "exact", "exact", "synthetic", "synthetic", "path"])
    #expect(log[2].template == "/users/{id}" && log[2].cassette == "GET__users_123_1.json")
    #expect(log[3].template == nil)
    #expect(log[9].cassette == nil)
  }

  @Test func brokenMatchRulesAreReportedOnce() async throws {
    state.mode = .replay
    try write("match.json", #"{"path_templates": "/users/{id}"}"#)
    try write("GET__books_1.json", #"{"request":{"method":"GET","url":"http://api/books","body":null},"response":{"status":200,"headers":{},"body":[]}}"#)
    let before = HarnessIssueLog.shared.count
    #expect(await request("GET", "http://api/books").status == 200)
    #expect(await request("GET", "http://api/books").status == 200)
    let issues = networkIssues(since: before)
    #expect(issues.count == 1 && issues[0].contains("match.json"))
  }

  @Test func recordingNamesTemplatedPathsAfterTheirTemplate() async throws {
    let server = try await LoopbackHTTPServer.start(status: 200, body: #"{"ok":true}"#)
    defer { server.stop() }
    try write("match.json", #"{"path_templates": ["/books/{id}"]}"#)
    state.mode = .record
    _ = await request("PUT", "http://127.0.0.1:\(server.port)/books/A1", body: #"{"read":true}"#)
    _ = await request("PUT", "http://127.0.0.1:\(server.port)/books/B2", body: #"{"read":true}"#)
    _ = await request("GET", "http://127.0.0.1:\(server.port)/books")
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(files == ["GET__books_1.json", "PUT__books_{id}_1.json", "PUT__books_{id}_2.json", "match.json"])
    #expect(state.requests().map(\.match) == ["live", "live", "live"])
    #expect(state.requests().map(\.cassette) == ["PUT__books_{id}_1.json", "PUT__books_{id}_2.json", "GET__books_1.json"])
    // Replay: the recorded ids match exactly, any other id through the template.
    server.stop()
    state.mode = .replay
    _ = await request("PUT", "http://api/books/B2", body: #"{"read":true}"#)
    _ = await request("PUT", "http://api/books/C3", body: #"{"read":true}"#)
    #expect(state.requests().suffix(2).map(\.match) == ["exact", "template"])
    #expect(state.requests().last?.cassette == "PUT__books_{id}_1.json")
  }

  @Test func faultsMatchConsumeAndApply() async throws {
    state.mode = .replay
    try write("GET__books_1.json", #"{"request":{"method":"GET","url":"http://api/books","body":null},"response":{"status":200,"headers":{},"body":[]}}"#)
    try write("POST__books_1.json", #"{"request":{"method":"POST","url":"http://api/books","body":null},"response":{"status":201,"headers":{},"body":{"id":1}}}"#)
    state.faults = [
      HarnessFault(match: .init(method: "post", path: "/books"), kind: .status, status: 500),
      HarnessFault(match: .init(path: "/books"), kind: .malformed, times: 2),
    ]
    let failed = await request("POST", "http://api/books")
    #expect(failed.status == 500 && failed.body.isEmpty)
    #expect(state.faults.map(\.kind) == [.malformed])
    // The status fault is used up; the malformed fault now matches any method on /books.
    let malformed = await request("POST", "http://api/books")
    #expect(malformed.status == 200)
    #expect((try? JSONSerialization.jsonObject(with: Data(malformed.body.utf8))) == nil)
    #expect(await request("GET", "http://api/books").status == 200)
    #expect(state.faults.isEmpty)
    #expect(await request("POST", "http://api/books").status == 201)
    #expect(state.requests().map(\.fault) == ["status", "malformed", "malformed", nil])
    #expect(state.requests().map(\.source) == ["fault", "fault", "fault", "fixture"])

    state.faults = [HarnessFault(kind: .offline, times: -1)]
    #expect(await request("GET", "http://api/books").error?.code == .notConnectedToInternet)
    #expect(await request("GET", "http://api/books").error?.code == .notConnectedToInternet)
    #expect(state.faults.count == 1)
    state.faults = [HarnessFault(kind: .timeout)]
    #expect(await request("GET", "http://api/books").error?.code == .timedOut)

    state.faults = [HarnessFault(match: .init(method: "GET"), kind: .delay, delayMs: 150)]
    let started = ContinuousClock.now
    #expect(state.snapshot().pending == 0)
    async let delayedRequest = request("GET", "http://api/books")
    try await Task.sleep(for: .milliseconds(50))
    #expect(state.snapshot().pending == 1)  // Started, not logged until it's answered.
    let delayed = await delayedRequest
    #expect(state.snapshot().pending == 0)
    #expect(ContinuousClock.now - started >= .milliseconds(150))
    #expect(delayed.status == 200 && delayed.body == "[]")
    let last = state.requests().last!
    #expect(last.source == "fixture" && last.fault == "delay" && last.ms >= 150)
  }

  @Test func replayLatencyKeepsRequestsInFlight() async throws {
    state.mode = .replay
    try write("GET__books_1.json", #"{"request":{"method":"GET","url":"http://api/books","body":null},"response":{"status":200,"headers":{},"body":[]}}"#)
    state.latency = HarnessLatency(ms: 120)
    let started = ContinuousClock.now
    async let slow = request("GET", "http://api/books")
    try await Task.sleep(for: .milliseconds(40))
    #expect(state.snapshot().pending == 1)
    #expect(await slow.status == 200)
    #expect(ContinuousClock.now - started >= .milliseconds(120))
    #expect(state.requests().last!.ms >= 120 && state.requests().last!.source == "fixture")
    #expect(state.snapshot().latency == HarnessLatency(ms: 120))

    // Only replay waits: block answers at once.
    state.mode = .block
    let blocked = ContinuousClock.now
    _ = await request("GET", "http://api/books")
    #expect(ContinuousClock.now - blocked < .milliseconds(100))
  }

  @Test func perPathLatencyReordersResponses() async throws {
    state.mode = .replay
    try write("GET__search_1.json", #"{"request":{"method":"GET","url":"http://api/search?q=du","body":null},"response":{"status":200,"headers":{},"body":["du"]}}"#)
    try write("GET__search_2.json", #"{"request":{"method":"GET","url":"http://api/search?q=dune","body":null},"response":{"status":200,"headers":{},"body":["dune"]}}"#)
    // The first search is slow, the second fast: the older response lands last.
    state.faults = [HarnessFault(match: .init(path: "/search"), kind: .delay, delayMs: 200)]
    state.latency = HarnessLatency(ms: 20)
    async let first = request("GET", "http://api/search?q=du")
    try await Task.sleep(for: .milliseconds(10))
    async let second = request("GET", "http://api/search?q=dune")
    _ = await (first, second)
    #expect(state.requests().map(\.url) == ["http://api/search?q=dune", "http://api/search?q=du"])
    #expect(state.requests().map(\.fault) == [nil, "delay"])
  }

  @Test func latencyJitterIsSeededAndPerPath() {
    let latency = HarnessLatency(ms: 200, jitterMs: 100, seed: 7, paths: ["/books/{id}": .init(ms: 10, jitterMs: 0), "/slow": .init(ms: 900)])
    let draws = (0..<50).map { latency.delayMs(method: "GET", path: "/books", occurrence: $0) }
    #expect(draws == (0..<50).map { latency.delayMs(method: "GET", path: "/books", occurrence: $0) })
    #expect(draws.allSatisfy { (100...300).contains($0) })
    #expect(Set(draws).count > 10)
    #expect(draws != (0..<50).map { latency.delayMs(method: "POST", path: "/books", occurrence: $0) })
    var reseeded = latency
    reseeded.seed = 8
    #expect(draws != (0..<50).map { reseeded.delayMs(method: "GET", path: "/books", occurrence: $0) })
    #expect(latency.delayMs(method: "PUT", path: "/books/42", occurrence: 3) == 10)
    #expect((800...1000).contains(latency.delayMs(method: "GET", path: "/slow", occurrence: 0)))
    // Without its own seed, the run's seed decides.
    let unseeded = HarnessLatency(ms: 200, jitterMs: 100)
    #expect(unseeded.delayMs(method: "GET", path: "/a", occurrence: 1, fallbackSeed: 1)
      == unseeded.delayMs(method: "GET", path: "/a", occurrence: 1, fallbackSeed: 1))
    #expect(HarnessLatency(ms: 50, jitterMs: 500).delayMs(method: "GET", path: "/a", occurrence: 0) >= 0)
  }

  @Test func latencyComesFromTheRunOrMatchRules() async throws {
    state.mode = .replay
    try write("GET__books_1.json", #"{"request":{"method":"GET","url":"http://api/books","body":null},"response":{"status":200,"headers":{},"body":[]}}"#)
    try write("match.json", #"{"latency": {"ms": 90, "jitter_ms": 0, "paths": {"/fast": {"ms": 0}}}}"#)
    #expect(state.snapshot().latency == HarnessLatency(ms: 90, paths: ["/fast": .init(ms: 0)]))
    let started = ContinuousClock.now
    _ = await request("GET", "http://api/books")
    #expect(ContinuousClock.now - started >= .milliseconds(90))
    state.latency = HarnessLatency(ms: 0)  // The run's latency wins over match.json.
    let quick = ContinuousClock.now
    _ = await request("GET", "http://api/books")
    #expect(ContinuousClock.now - quick < .milliseconds(80))

    let log = HarnessIssueLog()
    #expect(HarnessNetworkState(environment: ["TCA_HARNESS_LATENCY": "250"], issues: log).latency == HarnessLatency(ms: 250))
    let object = HarnessNetworkState(environment: ["TCA_HARNESS_LATENCY": #"{"ms":100,"jitter_ms":40,"seed":2}"#], issues: log)
    #expect(object.latency == HarnessLatency(ms: 100, jitterMs: 40, seed: 2))
    #expect(log.issues().isEmpty)
    #expect(HarnessNetworkState(environment: ["TCA_HARNESS_LATENCY": "soon"], issues: log).latency == nil)
    #expect(log.issues().map(\.message).first?.hasPrefix("Invalid TCA_HARNESS_LATENCY") == true)
  }

  @Test func sessionSetsLatency() async throws {
    let store = Store(initialState: Library.State()) { Library() }
    let attachment = store.harness(Library.self, timeline: nil, issues: HarnessIssueLog())
    let session = attachment.runtime.session
    let raw = await session.handleJSON(Data(#"{"method":"network","network":{"latency":{"ms":150,"jitter_ms":50}}}"#.utf8))
    let latency = (json(raw)["network"] as! [String: Any])["latency"] as! [String: Any]
    #expect(latency["ms"] as? Int == 150 && latency["jitter_ms"] as? Int == 50)
    #expect(state.latency == HarnessLatency(ms: 150, jitterMs: 50))
  }

  @Test func skipFailsTheNthMatchingRequest() async throws {
    state.mode = .replay
    try write("POST__books_1.json", #"{"request":{"method":"POST","url":"http://api/books","body":null},"response":{"status":201,"headers":{},"body":{"id":1}}}"#)
    // Fail the second POST; a fault still skipping must not hide a later fault that applies now.
    state.faults = [
      HarnessFault(match: .init(method: "POST", path: "/books"), kind: .status, status: 500, skip: 1),
      HarnessFault(match: .init(path: "/books"), kind: .status, status: 503, skip: 2),
    ]
    #expect(await request("POST", "http://api/books").status == 201)
    #expect(await request("POST", "http://api/books").status == 500)
    #expect(state.faults.map(\.status) == [503])
    #expect(await request("POST", "http://api/books").status == 503)
    #expect(state.faults.isEmpty)
    #expect(await request("POST", "http://api/books").status == 201)
    let decoded = try JSONDecoder().decode(HarnessFault.self, from: Data(#"{"kind":"offline","skip":2}"#.utf8))
    #expect(decoded.skip == 2 && decoded.times == 1)
  }

  @Test func recordSavesCassettesThatReplayServes() async throws {
    let server = try await LoopbackHTTPServer.start(status: 201, body: #"{"id":7,"title":"Dune"}"#)
    defer { server.stop() }
    state.mode = .record
    let url = "http://127.0.0.1:\(server.port)/books"
    let live = await request("POST", url, body: #"{"title":"Dune"}"#)
    #expect(live.status == 201 && live.body == #"{"id":7,"title":"Dune"}"#)
    #expect(state.requests().map(\.source) == ["live"])
    #expect(server.requests.first?.hasPrefix("POST /books HTTP/1.1") == true)
    #expect(server.requests.first?.hasSuffix(#"{"title":"Dune"}"#) == true)

    let file = directory.appendingPathComponent("POST__books_1.json")
    let cassette = try JSONDecoder().decode(HarnessCassette.self, from: Data(contentsOf: file))
    #expect(cassette.request.method == "POST")
    #expect(cassette.request.url == url)
    #expect(cassette.request.body == .object(["title": .string("Dune")]))
    #expect(cassette.response.status == 201)
    #expect(cassette.response.body == .object(["id": .number(7), "title": .string("Dune")]))

    server.stop()
    state.mode = .replay
    let replayed = await request("POST", url, body: #"{"title":"Dune"}"#)
    #expect(replayed.status == 201)
    #expect(json(Data(replayed.body.utf8))["id"] as? Int == 7)
    #expect(state.requests().last?.source == "fixture")
    #expect(server.requests.count == 1)
  }

  @Test func livePassesThroughAndLogs() async throws {
    let server = try await LoopbackHTTPServer.start(status: 200, body: "ok")
    defer { server.stop() }
    state.mode = .live
    let result = await request("GET", "http://127.0.0.1:\(server.port)/health?verbose=1")
    #expect(result.status == 200 && result.body == "ok")
    #expect(state.requests().map(\.source) == ["live"])
    #expect(state.requests().first?.url.hasSuffix("/health?verbose=1") == true)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(files.isEmpty)
  }

  @Test func liveGuardRefusesWritesAndOtherHostsInRecordAndLive() async throws {
    let server = try await LoopbackHTTPServer.start(status: 200, body: #"{"ok":true}"#)
    defer { server.stop(); state.liveGuard = nil }
    state.liveGuard = .readOnly(hosts: ["127.0.0.1"])
    let url = "http://127.0.0.1:\(server.port)/locations"
    for mode in [HarnessNetworkMode.record, .live] {
      state.mode = mode
      let before = HarnessIssueLog.shared.count
      let write = await request("PUT", url, body: #"{"device":"d"}"#)
      #expect(write.error?.code == .notConnectedToInternet)
      #expect(networkIssues(since: before) == ["Refused PUT 127.0.0.1/locations (live guard read-only (127.0.0.1))"])
      #expect(await request("POST", "http://example.invalid/messages", body: "{}").error?.code == .notConnectedToInternet)
      #expect(await request("GET", "http://localhost:\(server.port)/locations").error?.code == .notConnectedToInternet)
      #expect(await request("GET", url).status == 200)
    }
    // Only the two GETs reached the server; refused requests are logged as blocked and never saved.
    #expect(server.requests.count == 2 && server.requests.allSatisfy { $0.hasPrefix("GET /locations") })
    #expect(state.requests().map(\.source) == ["blocked", "blocked", "blocked", "live", "blocked", "blocked", "blocked", "live"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["GET__locations_1.json"])
    // reset() and the session's `network` method leave the guard in place.
    state.reset()
    #expect(state.snapshot().liveGuard == "read-only (127.0.0.1)")
    // Replay and faults never reach the network, so the guard doesn't apply to them.
    state.mode = .replay
    try write("PUT__locations_1.json", #"{"request":{"method":"PUT","url":"http://x/locations","body":null},"response":{"status":200,"headers":{},"body":{"status":"ok"}}}"#)
    #expect(await request("PUT", url).status == 200)
    #expect(server.requests.count == 2)
  }

  @Test func sessionReadsAndChangesTheNetwork() async throws {
    try write("POST__books_1.json", #"{"request":{"method":"POST","url":"http://api/books","body":null},"response":{"status":201,"headers":{},"body":{"id":1}}}"#)
    let store = Store(initialState: Library.State()) { Library() }
    let attachment = store.harness(Library.self, timeline: nil, issues: HarnessIssueLog())
    let session = attachment.runtime.session
    let change = #"{"method":"network","network":{"mode":"replay","faults":[{"match":{"method":"POST","path":"/books"},"kind":"status","status":500,"times":1},{"kind":"delay","delayMs":5,"times":-1,"match":{"path":"/slow"}}]}}"#
    let changed = json(await session.handleJSON(Data(change.utf8)))
    #expect(changed["ok"] as? Bool == true)
    #expect(state.mode == .replay)
    #expect(state.faults.count == 2)
    #expect(state.faults[0].times == 1)

    #expect(await request("POST", "http://api/books").status == 500)
    #expect(await request("POST", "http://api/books").status == 201)

    let raw = await session.handleJSON(Data(#"{"method":"network"}"#.utf8))
    print("PROTOCOL-EXAMPLE network:", String(decoding: raw, as: UTF8.self))
    let network = json(raw)["network"] as! [String: Any]
    #expect(network["mode"] as? String == "replay")
    #expect(network["cassettes"] as? String == directory.path)
    let requests = network["requests"] as! [[String: Any]]
    #expect(requests.map { $0["source"] as? String } == ["fault", "fixture"])
    #expect(requests.map { $0["status"] as? Int } == [500, 201])
    #expect(requests[0]["fault"] as? String == "status")
    #expect(requests[1]["fault"] is NSNull)
    #expect(requests[0]["method"] as? String == "POST" && requests[0]["url"] as? String == "http://api/books")
    #expect(requests[0]["ms"] is Int)
    let faults = network["faults"] as! [[String: Any]]
    #expect(faults.count == 1)
    #expect(faults[0]["kind"] as? String == "delay" && faults[0]["times"] as? Int == -1)
    #expect(json(raw)["observation"] != nil)

    let invalid = json(await session.handleJSON(Data(#"{"method":"network","network":{"mode":"offline"}}"#.utf8)))
    #expect(invalid["ok"] as? Bool == false && invalid["error"] as? String == "invalid_network_mode")
    let badFault = json(await session.handleJSON(Data(#"{"method":"network","network":{"faults":[{"kind":"status"}]}}"#.utf8)))
    #expect(badFault["ok"] as? Bool == false)
    #expect(state.mode == .replay)
  }

  @Test func environmentFaultsApplyFromTheFirstRequest() {
    let log = HarnessIssueLog()
    let faults = #"[{"match":{"method":"GET","path":"/books"},"kind":"status","status":503},{"kind":"offline","skip":1,"times":-1}]"#
    let configured = HarnessNetworkState(environment: ["TCA_HARNESS_NETWORK": "replay", "TCA_HARNESS_FAULTS": faults], issues: log)
    #expect(configured.faults == [
      HarnessFault(match: .init(method: "GET", path: "/books"), kind: .status, status: 503),
      HarnessFault(kind: .offline, times: -1, skip: 1),
    ])
    #expect(log.issues().isEmpty)
    let broken = HarnessNetworkState(environment: ["TCA_HARNESS_FAULTS": #"[{"kind":"status"}]"#], issues: log)
    #expect(broken.faults.isEmpty)
    #expect(log.issues().map(\.message).first?.hasPrefix("Invalid TCA_HARNESS_FAULTS") == true)
  }

  @Test func environmentConfiguresModeAndCassettes() {
    let log = HarnessIssueLog()
    let configured = HarnessNetworkState(environment: ["TCA_HARNESS_NETWORK": "replay", "TCA_HARNESS_CASSETTES": "/tmp/fixtures"], issues: log)
    #expect(configured.mode == .replay && configured.cassettes?.path == "/tmp/fixtures")
    #expect(HarnessNetworkState(environment: [:], issues: log).mode == .live)
    #expect(HarnessNetworkState(environment: ["TCA_HARNESS_NETWORK": "offline"], issues: log).mode == .live)
    #expect(log.issues().map(\.kind) == ["network"])
  }
}

/// Minimal loopback HTTP/1.1 responder for record and live tests.
final class LoopbackHTTPServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "LoopbackHTTPServer")
  private let status: Int
  private let body: String
  private let received = LockIsolated<[String]>([])
  var port: UInt16 { listener.port?.rawValue ?? 0 }
  var requests: [String] { received.value }

  private init(status: Int, body: String) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    self.status = status
    self.body = body
  }

  static func start(status: Int, body: String) async throws -> LoopbackHTTPServer {
    let server = try LoopbackHTTPServer(status: status, body: body)
    server.listener.newConnectionHandler = { [server] connection in
      connection.start(queue: server.queue)
      server.receive(connection, Data())
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let resumed = LockIsolated(false)
      server.listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if !resumed.withValue({ let was = $0; $0 = true; return was }) { continuation.resume() }
        case let .failed(error): if !resumed.withValue({ let was = $0; $0 = true; return was }) { continuation.resume(throwing: error) }
        default: break
        }
      }
      server.listener.start(queue: server.queue)
    }
    return server
  }

  func stop() { listener.cancel() }

  private func receive(_ connection: NWConnection, _ buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      let text = String(decoding: buffer, as: UTF8.self)
      if let headerEnd = text.range(of: "\r\n\r\n") {
        let headers = text[..<headerEnd.lowerBound].lowercased()
        let length = headers.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
          .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        if buffer.count - Data(text[..<headerEnd.upperBound].utf8).count >= length {
          self.received.withValue { $0.append(text) }
          let reason = self.status == 201 ? "Created" : "OK"
          let response = "HTTP/1.1 \(self.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(self.body.utf8.count)\r\nConnection: close\r\n\r\n\(self.body)"
          connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
          return
        }
      }
      if complete || error != nil { connection.cancel(); return }
      self.receive(connection, buffer)
    }
  }
}

private func report(_ message: String, fileID: StaticString = #fileID, line: UInt = #line) {
  reportIssue(message, fileID: fileID, line: line)
}
