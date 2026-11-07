import Foundation

/// How harness-routed requests are answered. Set with `TCA_HARNESS_NETWORK` or the session's `network` method.
public enum HarnessNetworkMode: String, Codable, Sendable, CaseIterable {
  /// Every request fails as if offline, and is reported as a `network` issue.
  case block
  /// Requests are answered from cassettes; a request with no cassette fails and is reported.
  case replay
  /// Requests go to the real network and each exchange is saved as a cassette.
  case record
  /// Requests go to the real network and are only logged.
  case live
}

/// A one-off or repeated failure injected into matching requests.
///
/// Wire form: `{"match":{"method":"POST","path":"/books"},"kind":"status","status":500,"times":1}`.
public struct HarnessFault: Codable, Sendable, Equatable {
  public struct Match: Codable, Sendable, Equatable {
    /// HTTP method, compared case-insensitively. Nil matches any method.
    public var method: String?
    /// URL path, compared exactly. Nil matches any path.
    public var path: String?
    public init(method: String? = nil, path: String? = nil) { self.method = method; self.path = path }
  }

  public enum Kind: String, Codable, Sendable {
    /// Respond with ``HarnessFault/status`` and an empty body.
    case status
    /// Fail with `URLError(.timedOut)`.
    case timeout
    /// Fail with `URLError(.notConnectedToInternet)`.
    case offline
    /// Respond 200 with a body that is not valid JSON.
    case malformed
    /// Wait ``HarnessFault/delayMs``, then answer normally.
    case delay
  }

  public var match: Match
  public var kind: Kind
  public var status: Int?
  public var delayMs: Int?
  /// Remaining number of requests to fail. `-1` means always.
  public var times: Int
  /// Matching requests to let through before failing, e.g. `1` fails the second one. They don't count toward `times`.
  public var skip: Int

  public init(match: Match = Match(), kind: Kind, status: Int? = nil, delayMs: Int? = nil, times: Int = 1, skip: Int = 0) {
    self.match = match; self.kind = kind; self.status = status; self.delayMs = delayMs; self.times = times; self.skip = skip
  }

  private enum CodingKeys: String, CodingKey { case match, kind, status, delayMs, times, skip }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    match = try container.decodeIfPresent(Match.self, forKey: .match) ?? Match()
    kind = try container.decode(Kind.self, forKey: .kind)
    status = try container.decodeIfPresent(Int.self, forKey: .status)
    delayMs = try container.decodeIfPresent(Int.self, forKey: .delayMs)
    times = try container.decodeIfPresent(Int.self, forKey: .times) ?? 1
    skip = max(0, try container.decodeIfPresent(Int.self, forKey: .skip) ?? 0)
    if kind == .status, status == nil {
      throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "A status fault needs `status`")
    }
  }

  func matches(method: String, path: String) -> Bool {
    (match.method.map { $0.caseInsensitiveCompare(method) == .orderedSame } ?? true) && (match.path.map { $0 == path } ?? true)
  }
}

/// Decides which requests may reach the real network in `record` and `live` mode.
///
/// Set it in-process on ``HarnessNetworkState/liveGuard``. The `network` method can change the mode but
/// not the guard, so a client that switches a run to `live` still can't send what the guard refuses.
/// Refused requests fail with `URLError.notConnectedToInternet`, are logged with source `blocked` and
/// reported as a `network` issue. Faults and replay are unaffected: they never reach the network.
public struct HarnessLiveGuard: Sendable {
  /// Shown in the `network` snapshot and in refusal messages.
  public var name: String
  public var allows: @Sendable (_ method: String, _ url: URL) -> Bool

  public init(name: String, allows: @escaping @Sendable (_ method: String, _ url: URL) -> Bool) {
    self.name = name; self.allows = allows
  }

  /// Only `GET` and `HEAD`, and when `hosts` is given only to those hosts or their subdomains.
  /// For recording fixtures from a production service without writing to it.
  public static func readOnly(hosts: Set<String>? = nil) -> Self {
    let hosts = hosts.map { Set($0.map { $0.lowercased() }) }
    let name = "read-only" + (hosts.map { " (" + $0.sorted().joined(separator: ", ") + ")" } ?? "")
    return Self(name: name) { method, url in
      guard ["GET", "HEAD"].contains(method.uppercased()) else { return false }
      guard let hosts else { return true }
      guard let host = url.host?.lowercased() else { return false }
      return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
  }
}

/// One request seen by the harness network layer.
public struct HarnessNetworkRequest: Codable, Sendable, Equatable {
  public let seq: Int
  public let method: String
  public let url: String
  /// HTTP status delivered to the app; nil when the request failed.
  public let status: Int?
  /// `fixture`, `live`, `fault` or `blocked`.
  public let source: String
  /// Kind of the injected fault, if one applied.
  public let fault: String?
  public let ms: Int

  public init(seq: Int, method: String, url: String, status: Int?, source: String, fault: String?, ms: Int) {
    self.seq = seq; self.method = method; self.url = url; self.status = status; self.source = source
    self.fault = fault; self.ms = ms
  }

  private enum CodingKeys: String, CodingKey { case seq, method, url, status, source, fault, ms }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(seq, forKey: .seq)
    try container.encode(method, forKey: .method)
    try container.encode(url, forKey: .url)
    try container.encode(status, forKey: .status)
    try container.encode(source, forKey: .source)
    try container.encode(fault, forKey: .fault)
    try container.encode(ms, forKey: .ms)
  }
}

/// The `network` value served by the session.
public struct HarnessNetworkSnapshot: Codable, Sendable, Equatable {
  public let mode: String
  public let cassettes: String?
  public let requests: [HarnessNetworkRequest]
  public let faults: [HarnessFault]
  /// Name of the ``HarnessLiveGuard``, if one is set.
  public let liveGuard: String?

  private enum CodingKeys: String, CodingKey { case mode, cassettes, requests, faults, liveGuard }

  public init(mode: String, cassettes: String?, requests: [HarnessNetworkRequest], faults: [HarnessFault], liveGuard: String? = nil) {
    self.mode = mode; self.cassettes = cassettes; self.requests = requests; self.faults = faults; self.liveGuard = liveGuard
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decode(String.self, forKey: .mode)
    cassettes = try container.decodeIfPresent(String.self, forKey: .cassettes)
    requests = try container.decode([HarnessNetworkRequest].self, forKey: .requests)
    faults = try container.decode([HarnessFault].self, forKey: .faults)
    liveGuard = try container.decodeIfPresent(String.self, forKey: .liveGuard)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(cassettes, forKey: .cassettes)
    try container.encode(requests, forKey: .requests)
    try container.encode(faults, forKey: .faults)
    try container.encodeIfPresent(liveGuard, forKey: .liveGuard)
  }
}

/// Mode, faults, cassettes and request log behind ``HarnessURLProtocol``. Thread-safe: the protocol
/// runs on URLSession's loading threads, the session reads it on the main actor.
public final class HarnessNetworkState: @unchecked Sendable {
  private let lock = NSLock()
  private var _mode: HarnessNetworkMode
  private var _cassettes: URL?
  private var _faults: [HarnessFault] = []
  private var _liveGuard: HarnessLiveGuard?
  private var requests: [HarnessNetworkRequest] = []
  private var sequence = 0
  /// Per method+path occurrence counters: replay serves equal recordings in order, record names files by occurrence.
  private var replayCounters: [String: Int] = [:]
  private var recordCounters: [String: Int] = [:]
  /// Where `network` issues (unmatched or blocked requests) are recorded.
  public let issues: HarnessIssueLog
  /// Maximum number of retained request log entries.
  public let capacity: Int

  public init(mode: HarnessNetworkMode = .live, cassettes: URL? = nil, issues: HarnessIssueLog = .shared, capacity: Int = 1000) {
    _mode = mode; _cassettes = cassettes; self.issues = issues; self.capacity = max(capacity, 1)
  }

  /// Reads `TCA_HARNESS_NETWORK` (`block`, `replay`, `record` or `live`; default `live`) and
  /// `TCA_HARNESS_CASSETTES` (cassette directory).
  public convenience init(environment: [String: String], issues: HarnessIssueLog = .shared) {
    let text = environment["TCA_HARNESS_NETWORK"]?.lowercased()
    let mode = text.flatMap(HarnessNetworkMode.init(rawValue:))
    self.init(mode: mode ?? .live, cassettes: environment["TCA_HARNESS_CASSETTES"].map { URL(fileURLWithPath: $0) }, issues: issues)
    if let text, !text.isEmpty, mode == nil {
      issues.record(kind: "network", message: "Unknown TCA_HARNESS_NETWORK value \(text); using live")
    }
  }

  public var mode: HarnessNetworkMode {
    get { locked { _mode } }
    set { locked { _mode = newValue } }
  }

  /// Cassette directory. Replay finds nothing and record saves nothing without one.
  public var cassettes: URL? {
    get { locked { _cassettes } }
    set { locked { _cassettes = newValue; replayCounters = [:]; recordCounters = [:] } }
  }

  /// Pending faults; exhausted ones are removed.
  public var faults: [HarnessFault] {
    get { locked { _faults } }
    set { locked { _faults = newValue } }
  }

  /// Limits what `record` and `live` send to the real network. Not changed by ``reset()`` or the
  /// `network` method.
  public var liveGuard: HarnessLiveGuard? {
    get { locked { _liveGuard } }
    set { locked { _liveGuard = newValue } }
  }

  /// Logged requests with `seq` greater than `since`, oldest first.
  public func requests(since: Int = 0) -> [HarnessNetworkRequest] { locked { requests.filter { $0.seq > since } } }

  public func snapshot(since: Int = 0) -> HarnessNetworkSnapshot {
    locked {
      HarnessNetworkSnapshot(mode: _mode.rawValue, cassettes: _cassettes?.path, requests: requests.filter { $0.seq > since }, faults: _faults,
        liveGuard: _liveGuard?.name)
    }
  }

  /// Clears the request log, faults and replay positions. Sequence numbers keep increasing.
  public func reset() {
    locked { requests = []; _faults = []; replayCounters = [:]; recordCounters = [:] }
  }

  // MARK: Used by the protocol

  func takeFault(method: String, path: String) -> HarnessFault? {
    locked {
      // Every matching fault that is still skipping counts this request; the first one that isn't applies.
      let matching = _faults.indices.filter { _faults[$0].times != 0 && _faults[$0].matches(method: method, path: path) }
      let index = matching.first { _faults[$0].skip == 0 }
      for i in matching where _faults[i].skip > 0 { _faults[i].skip -= 1 }
      guard let index else { return nil }
      let fault = _faults[index]
      if fault.times > 0 {
        _faults[index].times -= 1
        if _faults[index].times == 0 { _faults.remove(at: index) }
      }
      return fault
    }
  }

  func log(method: String, url: String, status: Int?, source: String, fault: String?, ms: Int) {
    locked {
      sequence += 1
      requests.append(HarnessNetworkRequest(seq: sequence, method: method, url: url, status: status, source: source, fault: fault, ms: ms))
      if requests.count > capacity { requests.removeFirst(requests.count - capacity) }
    }
  }

  /// Matching is by method and path, then by query and body. Equal recordings are served in order,
  /// repeating the last; otherwise the latest recording for the method and path is used.
  func fixture(for request: HarnessCassette.Request) -> HarnessCassette.Response? {
    guard let directory = cassettes else { return nil }
    let key = request.method.uppercased() + " " + request.path
    let candidates = HarnessCassette.load(directory: directory)
      .filter { $0.cassette.request.method.uppercased() == request.method.uppercased() && $0.cassette.request.path == request.path }
      .sorted { $0.number < $1.number }
    guard let latest = candidates.last else { return nil }
    let exact = candidates.filter { $0.cassette.request.query == request.query && $0.cassette.request.body == request.body }
    guard !exact.isEmpty else { return latest.cassette.response }
    let exactKey = key + "?" + (request.query ?? "") + "#" + String(describing: request.body)
    let position = locked { () -> Int in
      let position = replayCounters[exactKey, default: 0]
      replayCounters[exactKey] = position + 1
      return position
    }
    return exact[min(position, exact.count - 1)].cassette.response
  }

  /// Saves an exchange as `<METHOD>_<path with / as _>_<n>.json`, `n` counting this process's
  /// recordings of the same method and path from 1 (so re-recording replaces earlier files).
  func save(_ cassette: HarnessCassette) {
    guard let directory = cassettes else { return }
    let stem = cassette.request.method.uppercased() + "_" + cassette.request.path.replacingOccurrences(of: "/", with: "_")
    let number = locked { () -> Int in
      let next = recordCounters[stem, default: 0] + 1
      recordCounters[stem] = next
      return next
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try cassette.encoded().write(to: directory.appendingPathComponent("\(stem)_\(number).json"), options: .atomic)
    } catch {
      issues.record(kind: "network", message: "Could not save cassette \(stem)_\(number).json: \(error.localizedDescription)")
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body()
  }
}

/// One recorded exchange: `{request: {method, url, body}, response: {status, headers, body}}`.
///
/// A body is stored as its JSON value when it is JSON, otherwise as a string, and `null` when empty.
/// Bodies that are not UTF-8 are stored as base64 in `bodyBase64` instead.
public struct HarnessCassette: Codable, Sendable, Equatable {
  public struct Request: Codable, Sendable, Equatable {
    public var method: String
    public var url: String
    public var body: HarnessJSON
    public var bodyBase64: String?

    public init(method: String, url: String, body: Data?) {
      self.method = method; self.url = url
      (self.body, self.bodyBase64) = HarnessCassette.encodeBody(body)
    }

    var path: String { URLComponents(string: url)?.path ?? url }
    var query: String? { URLComponents(string: url)?.percentEncodedQuery }
  }

  public struct Response: Codable, Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: HarnessJSON
    public var bodyBase64: String?

    public init(status: Int, headers: [String: String], body: Data?) {
      self.status = status; self.headers = headers
      (self.body, self.bodyBase64) = HarnessCassette.encodeBody(body)
    }

    private enum CodingKeys: String, CodingKey { case status, headers, body, bodyBase64 }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      status = try container.decodeIfPresent(Int.self, forKey: .status) ?? 200
      headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
      body = try container.decodeIfPresent(HarnessJSON.self, forKey: .body) ?? .null
      bodyBase64 = try container.decodeIfPresent(String.self, forKey: .bodyBase64)
    }

    /// Bytes to deliver: the string as UTF-8, or the JSON value serialized.
    public var data: Data { HarnessCassette.decodeBody(body, bodyBase64) }
  }

  public var request: Request
  public var response: Response

  public init(request: Request, response: Response) { self.request = request; self.response = response }

  static func encodeBody(_ data: Data?) -> (HarnessJSON, String?) {
    guard let data, !data.isEmpty else { return (.null, nil) }
    guard let text = String(data: data, encoding: .utf8) else { return (.null, data.base64EncodedString()) }
    // A JSON string is kept as raw text so serving it back reproduces the same bytes.
    if let value = try? JSONDecoder().decode(HarnessJSON.self, from: data) {
      if case .string = value { return (.string(text), nil) }
      return (value, nil)
    }
    return (.string(text), nil)
  }

  static func decodeBody(_ body: HarnessJSON, _ base64: String?) -> Data {
    if let base64 { return Data(base64Encoded: base64) ?? Data() }
    switch body {
    case .null: return Data()
    case let .string(text): return Data(text.utf8)
    default: return (try? JSONEncoder().encode(body)) ?? Data()
    }
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// Every readable `*.json` cassette in `directory`, with the `n` from its file name (0 when absent).
  static func load(directory: URL) -> [(number: Int, cassette: HarnessCassette)] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { file in
      guard let data = try? Data(contentsOf: file), let cassette = try? JSONDecoder().decode(HarnessCassette.self, from: data)
      else { return nil }
      let stem = file.deletingPathExtension().lastPathComponent
      return (Int(stem.split(separator: "_").last ?? "") ?? 0, cassette)
    }
  }
}

/// Routes URLSession traffic through the harness so runs can block, replay, record or fault it.
///
/// ```swift
/// HarnessNetwork.install()                                                      // URLSession.shared
/// let session = URLSession(configuration: HarnessNetwork.configure(.ephemeral)) // custom sessions
/// ```
///
/// Reads `TCA_HARNESS_NETWORK` and `TCA_HARNESS_CASSETTES` when first used. Interception exists only
/// in builds compiled with `DEBUG`: elsewhere ``install()`` does nothing and ``configure(_:)`` returns
/// the configuration unchanged.
public enum HarnessNetwork {
  /// Process-wide state read by ``HarnessURLProtocol`` and served by the session's `network` method.
  public static let shared = HarnessNetworkState(environment: ProcessInfo.processInfo.environment)

  /// Whether interception is compiled in. False when compiled without `DEBUG`.
  public static var isAvailable: Bool {
#if DEBUG
    true
#else
    false
#endif
  }

  /// Routes `URLSession.shared` (and other sessions that consult registered protocol classes)
  /// through the harness. In `live` mode, the default, requests pass through and are logged.
  ///
  /// - Returns: Whether interception was installed; always false without `DEBUG`.
  @discardableResult
  public static func install() -> Bool {
#if DEBUG
    _ = shared
    URLProtocol.registerClass(HarnessURLProtocol.self)
    return true
#else
    return false
#endif
  }

  /// Stops routing `URLSession.shared` through the harness.
  public static func uninstall() {
#if DEBUG
    URLProtocol.unregisterClass(HarnessURLProtocol.self)
#endif
  }

  /// Returns `configuration` with ``HarnessURLProtocol`` first in its protocol classes, for sessions
  /// you create yourself.
  public static func configure(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
#if DEBUG
    _ = shared
    let others = (configuration.protocolClasses ?? []).filter { $0 != HarnessURLProtocol.self }
    configuration.protocolClasses = [HarnessURLProtocol.self] + others
#endif
    return configuration
  }
}

/// The URLProtocol behind ``HarnessNetwork``. Handles `http` and `https` requests using
/// ``HarnessNetwork/shared``.
public final class HarnessURLProtocol: URLProtocol, @unchecked Sendable {
  private static let handledKey = "TCAHarnessHandled"
  /// Performs live requests without re-entering the harness.
  private static let passthrough = URLSession(configuration: .ephemeral)

  private let lock = NSLock()
  private var liveTask: URLSessionDataTask?
  private var stopped = false
  private var runLoop: RunLoopBox?

  public override class func canInit(with request: URLRequest) -> Bool {
    guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    return property(forKey: handledKey, in: request) == nil
  }

  public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  public override func startLoading() {
    runLoop = RunLoopBox(CFRunLoopGetCurrent())
    let state = HarnessNetwork.shared
    let started = ContinuousClock.now
    let method = (request.httpMethod ?? "GET").uppercased()
    let url = request.url!
    let body = Self.body(of: request)
    let record = HarnessCassette.Request(method: method, url: url.absoluteString, body: body)
    let exchange = Exchange(state: state, started: started, method: method, url: url, record: record, body: body)
    guard let fault = state.takeFault(method: method, path: record.path) else { return answer(exchange, fault: nil) }
    switch fault.kind {
    case .status:
      respond(exchange, status: fault.status ?? 500, headers: [:], data: Data(), source: "fault", fault: "status")
    case .malformed:
      respond(exchange, status: 200, headers: ["Content-Type": "application/json"], data: Data(#"{"malformed": "#.utf8),
        source: "fault", fault: "malformed")
    case .timeout:
      fail(exchange, URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "Timed out (TCA harness fault)"]),
        source: "fault", fault: "timeout")
    case .offline:
      fail(exchange, URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Offline (TCA harness fault)"]),
        source: "fault", fault: "offline")
    case .delay:
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(fault.delayMs ?? 0, 0))) {
        self.answer(exchange, fault: "delay")
      }
    }
  }

  public override func stopLoading() {
    lock.lock(); stopped = true; let task = self.liveTask; lock.unlock()
    task?.cancel()
  }

  private struct Exchange {
    let state: HarnessNetworkState
    let started: ContinuousClock.Instant
    let method: String
    let url: URL
    let record: HarnessCassette.Request
    let body: Data?
    var elapsedMs: Int {
      let parts = (ContinuousClock.now - started).components
      return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
  }

  /// Answers according to the mode, after any delay fault.
  private func answer(_ exchange: Exchange, fault: String?) {
    let state = exchange.state
    let target = "\(exchange.method) \(exchange.record.path)"
    switch state.mode {
    case .block:
      state.issues.record(kind: "network", message: "Blocked \(target) (network mode block)")
      fail(exchange, URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Blocked by the TCA harness (network mode block)"]),
        source: "blocked", fault: fault)
    case .replay:
      guard let fixture = state.fixture(for: exchange.record) else {
        state.issues.record(kind: "network", message: "No fixture for \(target)")
        return fail(exchange, URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "No fixture for \(target) (TCA harness replay)"]),
          source: "blocked", fault: fault)
      }
      respond(exchange, status: fixture.status, headers: fixture.headers, data: fixture.data, source: "fixture", fault: fault)
    case .record, .live:
      let recording = state.mode == .record
      if let liveGuard = state.liveGuard, !liveGuard.allows(exchange.method, exchange.url) {
        state.issues.record(kind: "network", message: "Refused \(exchange.method) \(exchange.url.host ?? "")\(exchange.record.path) (live guard \(liveGuard.name))")
        return fail(exchange, URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Refused by the TCA harness live guard \(liveGuard.name)"]),
          source: "blocked", fault: fault)
      }
      if recording, state.cassettes == nil {
        state.issues.record(kind: "network", message: "Record mode without TCA_HARNESS_CASSETTES; \(target) was not saved")
      }
      var live = request
      if let body = exchange.body { live.httpBodyStream = nil; live.httpBody = body }
      let mutable = (live as NSURLRequest).mutableCopy() as! NSMutableURLRequest
      URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
      let task = Self.passthrough.dataTask(with: mutable as URLRequest) { data, response, error in
        if let error { return self.fail(exchange, error, source: "live", fault: fault) }
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
          if let key = pair.key as? String { result[key] = "\(pair.value)" }
        }
        let status = http?.statusCode ?? 200
        if recording {
          state.save(HarnessCassette(request: exchange.record, response: .init(status: status, headers: headers, body: data)))
        }
        self.respond(exchange, status: status, headers: headers, data: data ?? Data(), source: "live", fault: fault)
      }
      lock.lock(); let stopped = self.stopped; self.liveTask = task; lock.unlock()
      if !stopped { task.resume() }
    }
  }

  private func respond(_ exchange: Exchange, status: Int, headers: [String: String], data: Data, source: String, fault: String?) {
    exchange.state.log(method: exchange.method, url: exchange.url.absoluteString, status: status, source: source, fault: fault, ms: exchange.elapsedMs)
    // Delivered bytes are already decoded; drop headers that would make the client decode again.
    let delivered = headers.filter { !["content-encoding", "content-length", "transfer-encoding"].contains($0.key.lowercased()) }
    let response = HTTPURLResponse(url: exchange.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: delivered)!
    deliver { client in
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty { client.urlProtocol(self, didLoad: data) }
      client.urlProtocolDidFinishLoading(self)
    }
  }

  private func fail(_ exchange: Exchange, _ error: any Error, source: String, fault: String?) {
    exchange.state.log(method: exchange.method, url: exchange.url.absoluteString, status: nil, source: source, fault: fault, ms: exchange.elapsedMs)
    deliver { client in client.urlProtocol(self, didFailWithError: error) }
  }

  /// URLProtocol clients expect callbacks on the thread that started loading.
  private func deliver(_ body: @escaping @Sendable (any URLProtocolClient) -> Void) {
    lock.lock(); let stopped = self.stopped; lock.unlock()
    guard !stopped, let client, let runLoop else { return }
    let box = ClientBox(client)
    CFRunLoopPerformBlock(runLoop.value, CFRunLoopMode.commonModes.rawValue) { body(box.value) }
    CFRunLoopWakeUp(runLoop.value)
  }

  private static func body(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open(); defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class RunLoopBox: @unchecked Sendable {
  let value: CFRunLoop
  init(_ value: CFRunLoop) { self.value = value }
}

private final class ClientBox: @unchecked Sendable {
  let value: any URLProtocolClient
  init(_ value: any URLProtocolClient) { self.value = value }
}
