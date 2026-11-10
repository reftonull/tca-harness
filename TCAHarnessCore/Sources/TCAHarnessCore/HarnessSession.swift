import Foundation

public struct HarnessCandidate: Codable, Sendable {
  public let id: String
  public let feature: String
  public let label: String
  public let argumentSchema: HarnessArgumentSchema?
  public let instanceID: String?

  public init(id: String, feature: String, label: String, argumentSchema: HarnessArgumentSchema? = nil, instanceID: String? = nil) {
    self.id = id
    self.feature = feature
    self.label = label
    self.argumentSchema = argumentSchema
    self.instanceID = instanceID
  }
}

public enum HarnessOperationStatus: String, Codable, Sendable {
  case running, succeeded, failed, cancelled
}

@MainActor
public struct HarnessOperation {
  let status: () -> HarnessOperationStatus
  let cancel: (() -> Void)?
  public init(cancel: (() -> Void)? = nil, status: @escaping () -> HarnessOperationStatus) {
    self.cancel = cancel
    self.status = status
  }
  public static var completed: Self { Self { .succeeded } }
}

@MainActor
public struct HarnessOffer {
  public let candidate: HarnessCandidate
  let perform: (Data) throws -> HarnessOperation

  public init(candidate: HarnessCandidate, perform: @escaping (Data) throws -> HarnessOperation) {
    self.candidate = candidate
    self.perform = perform
  }

  /// Wrap execution while keeping the candidate, e.g. to attribute recorded actions.
  public func intercepting(_ around: @escaping (HarnessCandidate, () throws -> HarnessOperation) throws -> HarnessOperation) -> Self {
    let perform = self.perform, candidate = self.candidate
    return Self(candidate: candidate) { data in try around(candidate) { try perform(data) } }
  }

  public func scoped(feature: String, instanceID: String) -> Self {
    Self(candidate: HarnessCandidate(id: "\(feature)/\(candidate.id)@\(instanceID)", feature: feature,
      label: candidate.label, argumentSchema: candidate.argumentSchema, instanceID: instanceID), perform: perform)
  }

  public init(id: String, feature: String, label: String, perform: @escaping () -> HarnessOperation) {
    candidate = HarnessCandidate(id: id, feature: feature, label: label)
    self.perform = { _ in perform() }
  }

  public init<Arguments: Decodable>(
    id: String, feature: String, label: String,
    arguments: Arguments.Type, schema: HarnessArgumentSchema,
    validate: @escaping (Arguments) throws -> Void = { _ in },
    perform: @escaping (Arguments) -> HarnessOperation
  ) {
    candidate = HarnessCandidate(id: id, feature: feature, label: label, argumentSchema: schema)
    self.perform = { data in
      let arguments = try JSONDecoder().decode(Arguments.self, from: data)
      try validate(arguments)
      return perform(arguments)
    }
  }
}

private struct Request: Decodable {
  let method: String
  var sessionID: String?
  var requestID: String?
  var candidateID: String?
  var revision: Int?
  var timeoutMs: Int?
  var condition: String?
  var path: String?
  var since: Int?
  var arguments: [String: HarnessJSON]?
  var network: NetworkUpdate?
  /// `inspect` only: also return the descriptor's whole feature tree.
  var catalog: Bool?
}

/// `{"network":{"mode":"replay","faults":[...],"cassettes":"/abs/dir","latency":{"ms":200}}}`; every field is optional.
private struct NetworkUpdate: Decodable {
  var mode: String?
  var faults: [HarnessFault]?
  var cassettes: String?
  var latency: HarnessLatency?
}

/// An action case a feature has that no operation sends, and why (`ignored`, `unannotated`,
/// `binding`, `unsupported payload`, `multiple payloads`, or an app-supplied reason).
public struct HarnessUnexposedAction: Codable, Equatable, Sendable {
  public let action: String
  public let reason: String
  public init(action: String, reason: String) { self.action = action; self.reason = reason }
}

/// An operation a feature declares, whether or not it is available right now.
public struct HarnessDeclaredOperation: Codable, Equatable, Sendable {
  /// The route segment after the feature path, as in candidate IDs.
  public let id: String
  public let label: String
  public init(id: String, label: String) { self.id = id; self.label = label }
}

/// A feature the descriptor can mount, whether or not it is mounted now. Collection elements have
/// `{id}` as their segment, e.g. `root/books/{id}`.
public struct HarnessCatalogFeature: Codable, Equatable, Sendable {
  public let path: String
  public let name: String
  public let declaredOperations: [HarnessDeclaredOperation]
  public let unexposed: [HarnessUnexposedAction]
  public init(path: String, name: String, declaredOperations: [HarnessDeclaredOperation], unexposed: [HarnessUnexposedAction]) {
    self.path = path; self.name = name; self.declaredOperations = declaredOperations; self.unexposed = unexposed
  }
}

public struct HarnessFeatureInfo: Codable, Sendable {
  public let path: String
  public let name: String
  public let instanceID: String
  /// The operations available now.
  public let operations: [HarnessCandidate]
  /// Every operation the descriptor declares, available or not (`tca exposure`).
  public let declaredOperations: [HarnessDeclaredOperation]
  /// Action cases no operation sends (`tca exposure`).
  public let unexposed: [HarnessUnexposedAction]
  public init(path: String, name: String, instanceID: String, operations: [HarnessCandidate],
    declaredOperations: [HarnessDeclaredOperation] = [], unexposed: [HarnessUnexposedAction] = []) {
    self.path = path; self.name = name; self.instanceID = instanceID; self.operations = operations
    self.declaredOperations = declaredOperations; self.unexposed = unexposed
  }

  private enum CodingKeys: String, CodingKey { case path, name, instanceID, operations, declaredOperations, unexposed }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    path = try c.decode(String.self, forKey: .path)
    name = try c.decode(String.self, forKey: .name)
    instanceID = try c.decode(String.self, forKey: .instanceID)
    operations = try c.decode([HarnessCandidate].self, forKey: .operations)
    declaredOperations = try c.decodeIfPresent([HarnessDeclaredOperation].self, forKey: .declaredOperations) ?? []
    unexposed = try c.decodeIfPresent([HarnessUnexposedAction].self, forKey: .unexposed) ?? []
  }
}

private struct Observation<State: Encodable>: Encodable {
  let sessionID: String
  let revision: Int
  let state: State
  let candidates: [HarnessCandidate]
  /// Issues recorded so far (the latest issue `seq`); fetch them with the `issues` method.
  let issueCount: Int
}

private struct Receipt: Encodable {
  let requestID: String
  let candidateID: String
  let status: HarnessOperationStatus
}

private struct Response<State: Encodable>: Encodable {
  var ok = true
  var observation: Observation<State>?
  var receipt: Receipt?
  var verified: Bool?
  var error: String?
  var detail: String?
  var features: [HarnessFeatureInfo]?
  var catalog: [HarnessCatalogFeature]?
  var protocolVersion: Int?
  var diagnostics: [String]?
  var timeline: HarnessTimelinePage?
  var issues: [HarnessIssue]?
  var network: HarnessNetworkSnapshot?
}

/// Embeddable, model-independent execution session. Closures must address the
/// app's existing store. No store is created or copied by this package.
@MainActor
public final class HarnessSession<State: Codable & Equatable> {
  private let readState: () -> State
  private let readOffers: () -> [HarnessOffer]
  private let verify: (String) -> Bool?
  private let inspect: (() -> [HarnessFeatureInfo])?
  private let catalog: (() -> [HarnessCatalogFeature])?
  private let diagnostics: () -> [String]
  private let timeline: ((Int) -> HarnessTimelinePage?)?
  private let issueLog: HarnessIssueLog
  private let networkState: HarnessNetworkState
  private let beforeObserve: () -> Void
  private let sessionID = UUID().uuidString
  private var revision = 0
  private var previous: State?
  private var operations: [String: Operation] = [:]

  private struct Operation {
    let candidateID: String
    let expectedRevision: Int
    let arguments: [String: HarnessJSON]
    let operation: HarnessOperation
    var terminalStatus: HarnessOperationStatus?
  }

  public init(
    snapshot: @escaping () -> State,
    offers: @escaping () -> [HarnessOffer],
    verify: @escaping (String) -> Bool? = { _ in nil },
    inspect: (() -> [HarnessFeatureInfo])? = nil,
    catalog: (() -> [HarnessCatalogFeature])? = nil,
    diagnostics: @escaping () -> [String] = { [] },
    timeline: ((Int) -> HarnessTimelinePage?)? = nil,
    issues: HarnessIssueLog = .shared,
    network: HarnessNetworkState = HarnessNetwork.shared,
    beforeObserve: @escaping () -> Void = {}
  ) {
    readState = snapshot
    readOffers = offers
    self.verify = verify
    self.inspect = inspect
    self.catalog = catalog
    self.diagnostics = diagnostics
    self.timeline = timeline
    self.issueLog = issues
    self.networkState = network
    self.beforeObserve = beforeObserve
  }

  /// The protocol version reported by `inspect`. Version 3 added `issues`, `network` and `issueCount`;
  /// `declaredOperations` and `unexposed` on inspected features, and `inspect` with `"catalog": true`,
  /// were added later without a version change.
  public static var protocolVersion: Int { 3 }

  /// One JSON request in; one JSON response out. Transport is kept separate.
  public func handleJSON(_ data: Data) async -> Data {
    let response: Response<State>
    do {
      response = await handle(try JSONDecoder().decode(Request.self, from: data))
    } catch {
      response = Response(ok: false, error: "invalid_json_request")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(response)) ?? Data(#"{"ok":false,"error":"encoding_failed"}"#.utf8)
  }

  private func observe() -> Observation<State> {
    // Evaluates invariants, so violations are logged before issueCount is read.
    beforeObserve()
    let state = readState()
    if let previous, previous != state { revision += 1 }
    previous = state
    return Observation(sessionID: sessionID, revision: revision, state: state, candidates: readOffers().map(\.candidate),
      issueCount: issueLog.count)
  }

  private func receipt(_ id: String) -> Receipt {
    let operation = operations[id]!
    let status = operation.terminalStatus ?? operation.operation.status()
    if status != .running { operations[id]?.terminalStatus = status }
    return Receipt(requestID: id, candidateID: operation.candidateID, status: status)
  }

  private func failure(_ reason: String, detail: String? = nil) -> Response<State> {
    Response(ok: false, observation: observe(), error: reason, detail: detail)
  }

  private func handle(_ request: Request) async -> Response<State> {
    switch request.method {
    case "inspect":
      guard let inspect else { return failure("inspection_unavailable") }
      let features = inspect().filter { request.path == nil || $0.path == request.path || $0.path.hasPrefix(request.path! + "/") }
      return Response(observation: observe(), features: features, catalog: request.catalog == true ? catalog?() : nil,
        protocolVersion: Self.protocolVersion, diagnostics: diagnostics())
    case "observe":
      return Response(observation: observe())
    case "issues":
      let observation = observe()
      return Response(observation: observation, issues: issueLog.issues(since: max(request.since ?? 0, 0)))
    case "network":
      if let update = request.network {
        var mode: HarnessNetworkMode?
        if let text = update.mode {
          guard let value = HarnessNetworkMode(rawValue: text.lowercased()) else {
            return failure("invalid_network_mode", detail: "mode must be one of block, replay, record, live")
          }
          mode = value
        }
        if let mode { networkState.mode = mode }
        if let faults = update.faults { networkState.faults = faults }
        if let cassettes = update.cassettes { networkState.cassettes = cassettes.isEmpty ? nil : URL(fileURLWithPath: cassettes) }
        if let latency = update.latency { networkState.latency = latency }
      }
      return Response(observation: observe(), network: networkState.snapshot(since: max(request.since ?? 0, 0)))
    case "timeline":
      // Read-only development history; omits the observation to keep pages small.
      guard let page = timeline?(max(request.since ?? 0, 0)) else { return Response(ok: false, error: "timeline_unavailable") }
      return Response(timeline: page)
    case "dispatch":
      guard request.sessionID == sessionID else { return failure("wrong_session") }
      guard let id = request.requestID, !id.isEmpty,
        let candidateID = request.candidateID, let expected = request.revision
      else { return failure("dispatch_requires_requestID_candidateID_revision") }
      let arguments = request.arguments ?? [:]
      if let operation = operations[id] {
        guard operation.candidateID == candidateID, operation.expectedRevision == expected, operation.arguments == arguments
        else { return failure("request_id_conflict") }
        return Response(observation: observe(), receipt: receipt(id))
      }
      let current = observe()
      guard expected == current.revision else { return failure("stale_revision") }
      guard let offer = readOffers().first(where: { $0.candidate.id == candidateID })
      else { return failure("unavailable_candidate") }
      let result: HarnessOperation
      do {
        if let schema = offer.candidate.argumentSchema {
          try schema.validate(arguments)
        } else if !arguments.isEmpty {
          throw HarnessArgumentError("This operation accepts no arguments")
        }
        let data = try JSONEncoder().encode(arguments)
        for previousID in Array(operations.keys) { _ = receipt(previousID) }
        // Typed decoding and domain validation occur before the dispatch closure.
        // No suspension between validation and dispatch on the store actor.
        result = try offer.perform(data)
      } catch {
        return failure("invalid_arguments", detail: error.localizedDescription)
      }
      operations[id] = Operation(candidateID: candidateID, expectedRevision: expected, arguments: arguments, operation: result)
      return Response(observation: observe(), receipt: receipt(id))
    case "cancel":
      guard request.sessionID == sessionID else { return failure("wrong_session") }
      guard let id = request.requestID, let operation = operations[id] else { return failure("unknown_operation") }
      if receipt(id).status != .running { return Response(observation: observe(), receipt: receipt(id)) }
      guard let cancel = operation.operation.cancel else { return failure("cancellation_unavailable") }
      cancel()
      operations[id]?.terminalStatus = .cancelled
      return Response(observation: observe(), receipt: receipt(id))
    case "wait":
      guard request.sessionID == sessionID else { return failure("wrong_session") }
      guard let id = request.requestID, operations[id] != nil else { return failure("unknown_operation") }
      let timeout = min(max(request.timeoutMs ?? 3000, 1), 10000)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeout))
      while receipt(id).status == .running, ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(15)) }
        catch { return failure("wait_cancelled") }
      }
      let result = receipt(id)
      return Response(ok: result.status == .succeeded, observation: observe(), receipt: result,
        error: result.status == .running ? "wait_timeout" : (result.status == .succeeded ? nil : result.status.rawValue))
    case "verify":
      guard let condition = request.condition, let verified = verify(condition)
      else { return failure("unknown_verification_condition") }
      return Response(observation: observe(), verified: verified)
    default:
      return failure("unknown_method")
    }
  }
}
