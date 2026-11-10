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

/// Simulated response time for replayed requests, so a run's requests are genuinely in flight while
/// it goes on: double taps, dismissals mid-request and out-of-order responses become reachable.
///
/// Wire, `TCA_HARNESS_LATENCY` and `match.json` form (snake case, like the other matching rules):
///
/// ```json
/// {"ms": 200, "jitter_ms": 150, "seed": 3, "paths": {"/search": {"ms": 600}, "/books/{id}": {"ms": 50, "jitter_ms": 0}}}
/// ```
///
/// Each replayed request waits `ms` plus a jitter drawn uniformly from `-jitter_ms...jitter_ms`
/// (never below 0). The jitter is a pure function of the seed, the method and path and the request's
/// occurrence among requests with that method and path, so the same run waits the same on every
/// replay. `seed` defaults to `TCA_HARNESS_SEED`. A path rule (a literal path or a pattern with
/// `{name}`/`*` segments) replaces `ms`, and `jitter_ms` when it gives one; an exact path wins over
/// patterns, and patterns are tried in sorted order.
public struct HarnessLatency: Codable, Sendable, Equatable {
  public struct Rule: Codable, Sendable, Equatable {
    public var ms: Int
    public var jitterMs: Int?
    public init(ms: Int, jitterMs: Int? = nil) { self.ms = ms; self.jitterMs = jitterMs }
    private enum CodingKeys: String, CodingKey { case ms, jitterMs = "jitter_ms" }
  }

  public var ms: Int
  public var jitterMs: Int
  public var seed: UInt64?
  public var paths: [String: Rule]

  public init(ms: Int = 0, jitterMs: Int = 0, seed: UInt64? = nil, paths: [String: Rule] = [:]) {
    self.ms = ms; self.jitterMs = jitterMs; self.seed = seed; self.paths = paths
  }

  private enum CodingKeys: String, CodingKey { case ms, jitterMs = "jitter_ms", seed, paths }

  public init(from decoder: any Decoder) throws {
    // A bare number is a fixed latency: `TCA_HARNESS_LATENCY=200`.
    if let single = try? decoder.singleValueContainer(), let ms = try? single.decode(Int.self) {
      self.init(ms: ms)
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(ms: try container.decodeIfPresent(Int.self, forKey: .ms) ?? 0,
      jitterMs: try container.decodeIfPresent(Int.self, forKey: .jitterMs) ?? 0,
      seed: try container.decodeIfPresent(UInt64.self, forKey: .seed),
      paths: try container.decodeIfPresent([String: Rule].self, forKey: .paths) ?? [:])
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ms, forKey: .ms)
    try container.encode(jitterMs, forKey: .jitterMs)
    try container.encodeIfPresent(seed, forKey: .seed)
    if !paths.isEmpty { try container.encode(paths, forKey: .paths) }
  }

  /// Milliseconds to wait before answering the `occurrence`th (from 0) request with this method and
  /// path. `fallbackSeed` is used when the latency sets no `seed`.
  public func delayMs(method: String, path: String, occurrence: Int, fallbackSeed: UInt64 = 0) -> Int {
    let rule = paths[path] ?? paths.keys.sorted().first { HarnessMatchRules.path(path, matches: $0) }.flatMap { paths[$0] }
    let base = max(rule?.ms ?? ms, 0)
    let jitter = max(rule?.jitterMs ?? jitterMs, 0)
    guard jitter > 0 else { return base }
    var mix = (seed ?? fallbackSeed) ^ harnessFNV1a(method.uppercased() + " " + path) ^ (UInt64(occurrence) &* 0x9E37_79B9_7F4A_7C15)
    let draw = Int(harnessSplitMix(&mix) % UInt64(2 * jitter + 1)) - jitter
    return max(base + draw, 0)
  }
}

func harnessFNV1a(_ text: String) -> UInt64 {
  text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
}

func harnessSplitMix(_ state: inout UInt64) -> UInt64 {
  state &+= 0x9E37_79B9_7F4A_7C15
  var z = state
  z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
  z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
  return z ^ (z >> 31)
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
  /// How the request was answered (``HarnessMatch``): `exact`, `ordered`, `template`, `path`,
  /// `synthetic`, `fault`, `blocked` or `live`. Nil only in logs from older harness versions.
  public let match: String?
  /// File name of the cassette that answered (replay) or was written (record).
  public let cassette: String?
  /// The `match.json` path template the request matched, e.g. `/books/{id}`.
  public let template: String?

  public init(seq: Int, method: String, url: String, status: Int?, source: String, fault: String?, ms: Int,
    match: String? = nil, cassette: String? = nil, template: String? = nil) {
    self.seq = seq; self.method = method; self.url = url; self.status = status; self.source = source
    self.fault = fault; self.ms = ms; self.match = match; self.cassette = cassette; self.template = template
  }

  private enum CodingKeys: String, CodingKey { case seq, method, url, status, source, fault, ms, match, cassette, template }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(seq, forKey: .seq)
    try container.encode(method, forKey: .method)
    try container.encode(url, forKey: .url)
    try container.encode(status, forKey: .status)
    try container.encode(source, forKey: .source)
    try container.encode(fault, forKey: .fault)
    try container.encode(ms, forKey: .ms)
    try container.encode(match, forKey: .match)
    try container.encodeIfPresent(cassette, forKey: .cassette)
    try container.encodeIfPresent(template, forKey: .template)
  }
}

/// How a logged request was answered, from most to least trustworthy for replay.
public enum HarnessMatch: String, Codable, Sendable, CaseIterable {
  /// A cassette with the same method, path, query and body (after `match.json` ignores).
  case exact
  /// Like `exact`, but several equal recordings exist and this one was picked by occurrence.
  case ordered
  /// No cassette for this path; one recorded for the same `match.json` path template, with equal query and body.
  case template
  /// Fallback: the latest cassette for the method and path (or template); query or body differed.
  case path
  /// No recording; answered by a `match.json` rule (the terminal page of a paginated endpoint).
  case synthetic
  /// An injected fault answered (status, malformed, timeout, offline).
  case fault
  /// Failed without reaching anything: no fixture, network mode `block`, or the live guard.
  case blocked
  /// Sent to the real network (`live` or `record`).
  case live
}

/// Matching rules for one cassette directory, read from `match.json` beside the cassettes.
///
/// ```json
/// {
///   "ignore_query": ["t"],
///   "path_templates": ["/books/{id}", "/rides/{id}/attendees"],
///   "paths": {"/events": {"ignore_body": true}, "/nearby": {"ignore_query": ["lat", "lon"]}},
///   "pagination": [{"path": "/timeline", "cursor": "max_id", "terminal": {"status": 200, "body": []}}]
/// }
/// ```
///
/// Path patterns are literal paths in which a `{name}` or `*` segment matches any one segment.
public struct HarnessMatchRules: Decodable, Sendable, Equatable {
  public struct PathRule: Decodable, Sendable, Equatable {
    /// Query parameters left out when comparing a request with a cassette.
    public var ignoreQuery: [String]
    /// Compare only method, path and query; the body never prevents a match.
    public var ignoreBody: Bool

    private enum CodingKeys: String, CodingKey { case ignoreQuery = "ignore_query", ignoreBody = "ignore_body" }
    public init(ignoreQuery: [String] = [], ignoreBody: Bool = false) { self.ignoreQuery = ignoreQuery; self.ignoreBody = ignoreBody }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      ignoreQuery = try container.decodeIfPresent([String].self, forKey: .ignoreQuery) ?? []
      ignoreBody = try container.decodeIfPresent(Bool.self, forKey: .ignoreBody) ?? false
    }
  }

  public struct Pagination: Decodable, Sendable, Equatable {
    /// Path pattern of the paginated endpoint.
    public var path: String
    /// Query parameters that ask for a later page (`max_id`, `cursor`, `page`).
    public var cursor: [String]
    /// Served when a later page has no cassette. Defaults to status 200 with an empty JSON array.
    public var terminal: HarnessCassette.Response

    private enum CodingKeys: String, CodingKey { case path, cursor, terminal }
    public init(path: String, cursor: [String], terminal: HarnessCassette.Response? = nil) {
      self.path = path; self.cursor = cursor
      self.terminal = terminal ?? HarnessCassette.Response(status: 200, headers: ["Content-Type": "application/json"], body: Data("[]".utf8))
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let path = try container.decode(String.self, forKey: .path)
      let cursor: [String]
      if let names = try? container.decode([String].self, forKey: .cursor) { cursor = names } else {
        cursor = [try container.decode(String.self, forKey: .cursor)]
      }
      self.init(path: path, cursor: cursor, terminal: try container.decodeIfPresent(HarnessCassette.Response.self, forKey: .terminal))
      if terminal.headers.isEmpty { terminal.headers = ["Content-Type": "application/json"] }
    }
  }

  /// Ignored for every path.
  public var ignoreQuery: [String]
  /// Paths whose cassettes stand in for each other when no cassette has the exact path.
  public var pathTemplates: [String]
  /// Per path pattern; every matching pattern applies.
  public var paths: [String: PathRule]
  public var pagination: [Pagination]
  /// Replay latency for this directory's cassettes, unless the run sets one (`TCA_HARNESS_LATENCY`
  /// or the `network` method).
  public var latency: HarnessLatency?

  private enum CodingKeys: String, CodingKey {
    case ignoreQuery = "ignore_query", pathTemplates = "path_templates", paths, pagination, latency
  }

  public init(ignoreQuery: [String] = [], pathTemplates: [String] = [], paths: [String: PathRule] = [:], pagination: [Pagination] = [],
    latency: HarnessLatency? = nil) {
    self.ignoreQuery = ignoreQuery; self.pathTemplates = pathTemplates; self.paths = paths; self.pagination = pagination
    self.latency = latency
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ignoreQuery = try container.decodeIfPresent([String].self, forKey: .ignoreQuery) ?? []
    pathTemplates = try container.decodeIfPresent([String].self, forKey: .pathTemplates) ?? []
    paths = try container.decodeIfPresent([String: PathRule].self, forKey: .paths) ?? [:]
    pagination = try container.decodeIfPresent([Pagination].self, forKey: .pagination) ?? []
    latency = try container.decodeIfPresent(HarnessLatency.self, forKey: .latency)
  }

  /// Whether `pattern` (`/books/{id}`, `/books/*`) matches `path` segment for segment.
  public static func path(_ path: String, matches pattern: String) -> Bool {
    if path == pattern { return true }
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count == parts.count else { return false }
    return zip(segments, parts).allSatisfy { segment, part in
      part == "*" || (part.hasPrefix("{") && part.hasSuffix("}")) ? !segment.isEmpty : segment == part
    }
  }

  /// The first path template that matches `path`.
  public func template(for path: String) -> String? { pathTemplates.first { Self.path(path, matches: $0) } }

  func ignoredQuery(for path: String) -> Set<String> {
    Set(ignoreQuery + paths.filter { Self.path(path, matches: $0.key) }.flatMap(\.value.ignoreQuery))
  }

  func ignoresBody(for path: String) -> Bool { paths.contains { $0.value.ignoreBody && Self.path(path, matches: $0.key) } }

  /// The pagination rule for a request that asks for a later page of a paginated endpoint.
  func laterPage(path: String, query: [URLQueryItem]) -> Pagination? {
    pagination.first { rule in
      Self.path(path, matches: rule.path) && query.contains { rule.cursor.contains($0.name) && !($0.value ?? "").isEmpty }
    }
  }

  /// `match.json` in `directory`: nil when absent, an error message when it doesn't parse.
  static func load(directory: URL) -> (rules: HarnessMatchRules?, error: String?) {
    let file = directory.appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: file) else { return (nil, nil) }
    do { return (try JSONDecoder().decode(Self.self, from: data), nil) } catch {
      return (nil, "Could not read \(file.path): \(error)")
    }
  }

  public static let fileName = "match.json"
}

/// The `network` value served by the session.
public struct HarnessNetworkSnapshot: Codable, Sendable, Equatable {
  public let mode: String
  public let cassettes: String?
  public let requests: [HarnessNetworkRequest]
  public let faults: [HarnessFault]
  /// Name of the ``HarnessLiveGuard``, if one is set.
  public let liveGuard: String?
  /// Requests started but not yet answered (they're logged when they finish). Nil from older versions.
  public let pending: Int?
  /// Replay latency in effect: the run's, else the cassette directory's `match.json`. Nil when none.
  public let latency: HarnessLatency?

  private enum CodingKeys: String, CodingKey { case mode, cassettes, requests, faults, liveGuard, pending, latency }

  public init(mode: String, cassettes: String?, requests: [HarnessNetworkRequest], faults: [HarnessFault], liveGuard: String? = nil,
    pending: Int? = nil, latency: HarnessLatency? = nil) {
    self.mode = mode; self.cassettes = cassettes; self.requests = requests; self.faults = faults; self.liveGuard = liveGuard
    self.pending = pending; self.latency = latency
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decode(String.self, forKey: .mode)
    cassettes = try container.decodeIfPresent(String.self, forKey: .cassettes)
    requests = try container.decode([HarnessNetworkRequest].self, forKey: .requests)
    faults = try container.decode([HarnessFault].self, forKey: .faults)
    liveGuard = try container.decodeIfPresent(String.self, forKey: .liveGuard)
    pending = try container.decodeIfPresent(Int.self, forKey: .pending)
    latency = try container.decodeIfPresent(HarnessLatency.self, forKey: .latency)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(cassettes, forKey: .cassettes)
    try container.encode(requests, forKey: .requests)
    try container.encode(faults, forKey: .faults)
    try container.encodeIfPresent(liveGuard, forKey: .liveGuard)
    try container.encodeIfPresent(pending, forKey: .pending)
    try container.encodeIfPresent(latency, forKey: .latency)
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
  /// Last `match.json` parse error reported, so a broken file is reported once, not per request.
  private var rulesError: String?
  /// Requests started and not yet logged.
  private var pending = 0
  /// The run's replay latency; nil defers to `match.json`.
  private var _latency: HarnessLatency?
  /// Per method+path occurrence counters for latency jitter, in the order requests start.
  private var latencyCounters: [String: Int] = [:]
  /// `TCA_HARNESS_SEED`, the default latency seed.
  private var runSeed: UInt64 = 0
  /// Where `network` issues (unmatched or blocked requests) are recorded.
  public let issues: HarnessIssueLog
  /// Maximum number of retained request log entries.
  public let capacity: Int

  public init(mode: HarnessNetworkMode = .live, cassettes: URL? = nil, issues: HarnessIssueLog = .shared, capacity: Int = 1000) {
    _mode = mode; _cassettes = cassettes; self.issues = issues; self.capacity = max(capacity, 1)
  }

  /// Reads `TCA_HARNESS_NETWORK` (`block`, `replay`, `record` or `live`; default `live`),
  /// `TCA_HARNESS_CASSETTES` (cassette directory), `TCA_HARNESS_FAULTS` (a JSON array of faults,
  /// pending from the first request, so they reach requests made before a client connects),
  /// `TCA_HARNESS_LATENCY` (replay latency, ``HarnessLatency``: milliseconds or a JSON object) and
  /// `TCA_HARNESS_SEED` (the default seed of the latency jitter).
  public convenience init(environment: [String: String], issues: HarnessIssueLog = .shared) {
    let text = environment["TCA_HARNESS_NETWORK"]?.lowercased()
    let mode = text.flatMap(HarnessNetworkMode.init(rawValue:))
    self.init(mode: mode ?? .live, cassettes: environment["TCA_HARNESS_CASSETTES"].map { URL(fileURLWithPath: $0) }, issues: issues)
    if let text, !text.isEmpty, mode == nil {
      issues.record(kind: "network", message: "Unknown TCA_HARNESS_NETWORK value \(text); using live")
    }
    if let faults = environment["TCA_HARNESS_FAULTS"], !faults.trimmingCharacters(in: .whitespaces).isEmpty {
      do {
        _faults = try JSONDecoder().decode([HarnessFault].self, from: Data(faults.utf8))
      } catch {
        issues.record(kind: "network", message: "Invalid TCA_HARNESS_FAULTS (a JSON array of faults): \(error)")
      }
    }
    if let seed = environment["TCA_HARNESS_SEED"]?.trimmingCharacters(in: .whitespaces), !seed.isEmpty {
      runSeed = UInt64(seed) ?? Int64(seed).map { UInt64(bitPattern: $0) } ?? harnessFNV1a(seed)
    }
    if let latency = environment["TCA_HARNESS_LATENCY"], !latency.trimmingCharacters(in: .whitespaces).isEmpty {
      do {
        _latency = try JSONDecoder().decode(HarnessLatency.self, from: Data(latency.utf8))
      } catch {
        issues.record(kind: "network", message: "Invalid TCA_HARNESS_LATENCY (milliseconds or a latency object): \(error)")
      }
    }
  }

  public var mode: HarnessNetworkMode {
    get { locked { _mode } }
    set { locked { _mode = newValue } }
  }

  /// Cassette directory. Replay finds nothing and record saves nothing without one.
  public var cassettes: URL? {
    get { locked { _cassettes } }
    set { locked { _cassettes = newValue; replayCounters = [:]; recordCounters = [:]; latencyCounters = [:] } }
  }

  /// Pending faults; exhausted ones are removed.
  public var faults: [HarnessFault] {
    get { locked { _faults } }
    set { locked { _faults = newValue } }
  }

  /// The run's replay latency. Nil (the default) uses the cassette directory's `match.json` `latency`, if any.
  public var latency: HarnessLatency? {
    get { locked { _latency } }
    set { locked { _latency = newValue; latencyCounters = [:] } }
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
        liveGuard: _liveGuard?.name, pending: pending, latency: _latency ?? _cassettes.flatMap { HarnessMatchRules.load(directory: $0).rules?.latency })
    }
  }

  /// Clears the request log, faults, latency and replay positions. Sequence numbers keep increasing.
  public func reset() {
    locked { requests = []; _faults = []; _latency = nil; replayCounters = [:]; recordCounters = [:]; latencyCounters = [:] }
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

  func started() { locked { pending += 1 } }

  /// How long to hold a request before answering it: the replay latency, in replay mode only.
  func replayDelayMs(method: String, path: String) -> Int {
    guard mode == .replay else { return 0 }
    let configured = latency ?? cassettes.flatMap { rules(in: $0)?.latency }
    guard let configured else { return 0 }
    let key = method.uppercased() + " " + path
    let (occurrence, seed) = locked { () -> (Int, UInt64) in
      let occurrence = latencyCounters[key, default: 0]
      latencyCounters[key] = occurrence + 1
      return (occurrence, runSeed)
    }
    return configured.delayMs(method: method, path: path, occurrence: occurrence, fallbackSeed: seed)
  }

  /// A started request that will never be logged (stopped before it was sent).
  func abandoned() { locked { pending = max(pending - 1, 0) } }

  func log(method: String, url: String, status: Int?, source: String, fault: String?, ms: Int, answer: Answer) {
    locked {
      pending = max(pending - 1, 0)
      sequence += 1
      requests.append(HarnessNetworkRequest(seq: sequence, method: method, url: url, status: status, source: source, fault: fault, ms: ms,
        match: answer.match.rawValue, cassette: answer.cassette, template: answer.template))
      if requests.count > capacity { requests.removeFirst(requests.count - capacity) }
    }
  }

  /// How a request was answered, for the log.
  struct Answer {
    var match: HarnessMatch
    var cassette: String? = nil
    var template: String? = nil
  }

  /// The cassette response for a replayed request, and how it matched.
  ///
  /// Candidates are the cassettes with the same method and path; when there are none, those whose
  /// path fits the same `match.json` path template. Among them, equal query and body (after the
  /// rules' ignores) is a match; equal recordings are served in order, repeating the last. A later
  /// page of a paginated endpoint with no match gets the rule's terminal page. Otherwise the latest
  /// candidate is the fallback.
  func fixture(for request: HarnessCassette.Request) -> (response: HarnessCassette.Response, answer: Answer)? {
    guard let directory = cassettes else { return nil }
    let rules = self.rules(in: directory) ?? HarnessMatchRules()
    let method = request.method.uppercased()
    let path = request.path
    let all = HarnessCassette.load(directory: directory).filter { $0.cassette.request.method.uppercased() == method }
      .sorted { ($0.number, $0.file) < ($1.number, $1.file) }
    var candidates = all.filter { $0.cassette.request.path == path }
    var template: String?
    if candidates.isEmpty, let match = rules.template(for: path) {
      candidates = all.filter { HarnessMatchRules.path($0.cassette.request.path, matches: match) }
      if !candidates.isEmpty { template = match }
    }
    let ignored = rules.ignoredQuery(for: path)
    let ignoreBody = rules.ignoresBody(for: path)
    let query = Self.normalized(request, ignoring: ignored)
    let exact = candidates.filter {
      Self.normalized($0.cassette.request, ignoring: ignored) == query && (ignoreBody || $0.cassette.request.body == request.body)
    }
    if !exact.isEmpty {
      let key = method + " " + (template ?? path) + "?" + query + "#" + (ignoreBody ? "" : String(describing: request.body))
      let position = locked { () -> Int in
        let position = replayCounters[key, default: 0]
        replayCounters[key] = position + 1
        return position
      }
      let served = exact[min(position, exact.count - 1)]
      let match: HarnessMatch = template != nil ? .template : exact.count > 1 ? .ordered : .exact
      return (served.cassette.response, Answer(match: match, cassette: served.file, template: template))
    }
    let items = URLComponents(string: request.url)?.queryItems ?? []
    if let page = rules.laterPage(path: path, query: items) {
      return (page.terminal, Answer(match: .synthetic, template: template))
    }
    guard let latest = candidates.last else { return nil }
    return (latest.cassette.response, Answer(match: .path, cassette: latest.file, template: template))
  }

  /// The query compared for matching: as sent, or without the ignored parameters.
  private static func normalized(_ request: HarnessCassette.Request, ignoring ignored: Set<String>) -> String {
    guard !ignored.isEmpty, let components = URLComponents(string: request.url) else { return request.query ?? "" }
    return (components.percentEncodedQueryItems ?? []).filter { !ignored.contains($0.name) }
      .map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&")
  }

  /// `match.json` for `directory`; a file that doesn't parse is reported once per distinct error.
  func rules(in directory: URL) -> HarnessMatchRules? {
    let (rules, error) = HarnessMatchRules.load(directory: directory)
    let report = locked { () -> Bool in
      defer { rulesError = error }
      return error != nil && error != rulesError
    }
    if report, let error { issues.record(kind: "network", message: error) }
    return rules
  }

  /// Saves an exchange as `<METHOD>_<path with / as _>_<n>.json`, `n` counting this process's
  /// recordings of the same method and path from 1 (so re-recording replaces earlier files). A path
  /// that fits a `match.json` template is named after the template (`PUT__books_{id}_1.json`), so
  /// recordings of the same endpoint for different ids share one name and count.
  @discardableResult
  func save(_ cassette: HarnessCassette) -> String? {
    guard let directory = cassettes else { return nil }
    let path = rules(in: directory)?.template(for: cassette.request.path) ?? cassette.request.path
    let stem = cassette.request.method.uppercased() + "_" + path.replacingOccurrences(of: "/", with: "_")
    let number = locked { () -> Int in
      let next = recordCounters[stem, default: 0] + 1
      recordCounters[stem] = next
      return next
    }
    let name = "\(stem)_\(number).json"
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try cassette.encoded().write(to: directory.appendingPathComponent(name), options: .atomic)
      return name
    } catch {
      issues.record(kind: "network", message: "Could not save cassette \(name): \(error.localizedDescription)")
      return nil
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

  /// Every readable `*.json` cassette in `directory` (not `match.json`), with its file name and the
  /// `n` from that name (0 when absent).
  static func load(directory: URL) -> [(number: Int, file: String, cassette: HarnessCassette)] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != HarnessMatchRules.fileName }.compactMap { file in
      guard let data = try? Data(contentsOf: file), let cassette = try? JSONDecoder().decode(HarnessCassette.self, from: data)
      else { return nil }
      let stem = file.deletingPathExtension().lastPathComponent
      return (Int(stem.split(separator: "_").last ?? "") ?? 0, file.lastPathComponent, cassette)
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
/// Reads `TCA_HARNESS_NETWORK`, `TCA_HARNESS_CASSETTES` and `TCA_HARNESS_FAULTS` when first used. Interception exists only
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
    state.started()
    // Faults are taken and latency drawn when the request starts, so both follow start order.
    let fault = state.takeFault(method: method, path: record.path)
    let latency = state.replayDelayMs(method: method, path: record.path)
    guard latency > 0 else { return reply(exchange, fault: fault) }
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(latency)) { self.reply(exchange, fault: fault) }
  }

  /// Answers with `fault`, or normally (after a delay fault's wait).
  private func reply(_ exchange: Exchange, fault: HarnessFault?) {
    guard let fault else { return answer(exchange, fault: nil) }
    switch fault.kind {
    case .status:
      respond(exchange, status: fault.status ?? 500, headers: [:], data: Data(), source: "fault", fault: "status", answer: .init(match: .fault))
    case .malformed:
      respond(exchange, status: 200, headers: ["Content-Type": "application/json"], data: Data(#"{"malformed": "#.utf8),
        source: "fault", fault: "malformed", answer: .init(match: .fault))
    case .timeout:
      fail(exchange, URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "Timed out (TCA harness fault)"]),
        source: "fault", fault: "timeout", answer: .init(match: .fault))
    case .offline:
      fail(exchange, URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Offline (TCA harness fault)"]),
        source: "fault", fault: "offline", answer: .init(match: .fault))
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
        source: "blocked", fault: fault, answer: .init(match: .blocked))
    case .replay:
      guard let (fixture, answer) = state.fixture(for: exchange.record) else {
        state.issues.record(kind: "network", message: "No fixture for \(target)")
        return fail(exchange, URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "No fixture for \(target) (TCA harness replay)"]),
          source: "blocked", fault: fault, answer: .init(match: .blocked))
      }
      respond(exchange, status: fixture.status, headers: fixture.headers, data: fixture.data, source: "fixture", fault: fault, answer: answer)
    case .record, .live:
      let recording = state.mode == .record
      if let liveGuard = state.liveGuard, !liveGuard.allows(exchange.method, exchange.url) {
        state.issues.record(kind: "network", message: "Refused \(exchange.method) \(exchange.url.host ?? "")\(exchange.record.path) (live guard \(liveGuard.name))")
        return fail(exchange, URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Refused by the TCA harness live guard \(liveGuard.name)"]),
          source: "blocked", fault: fault, answer: .init(match: .blocked))
      }
      if recording, state.cassettes == nil {
        state.issues.record(kind: "network", message: "Record mode without TCA_HARNESS_CASSETTES; \(target) was not saved")
      }
      var live = request
      if let body = exchange.body { live.httpBodyStream = nil; live.httpBody = body }
      let mutable = (live as NSURLRequest).mutableCopy() as! NSMutableURLRequest
      URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
      let task = Self.passthrough.dataTask(with: mutable as URLRequest) { data, response, error in
        if let error { return self.fail(exchange, error, source: "live", fault: fault, answer: .init(match: .live)) }
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
          if let key = pair.key as? String { result[key] = "\(pair.value)" }
        }
        let status = http?.statusCode ?? 200
        var answer = HarnessNetworkState.Answer(match: .live)
        if recording {
          answer.cassette = state.save(HarnessCassette(request: exchange.record, response: .init(status: status, headers: headers, body: data)))
        }
        self.respond(exchange, status: status, headers: headers, data: data ?? Data(), source: "live", fault: fault, answer: answer)
      }
      lock.lock(); let stopped = self.stopped; self.liveTask = task; lock.unlock()
      if stopped { state.abandoned() } else { task.resume() }
    }
  }

  private func respond(_ exchange: Exchange, status: Int, headers: [String: String], data: Data, source: String, fault: String?,
    answer: HarnessNetworkState.Answer) {
    exchange.state.log(method: exchange.method, url: exchange.url.absoluteString, status: status, source: source, fault: fault,
      ms: exchange.elapsedMs, answer: answer)
    // Delivered bytes are already decoded; drop headers that would make the client decode again.
    let delivered = headers.filter { !["content-encoding", "content-length", "transfer-encoding"].contains($0.key.lowercased()) }
    let response = HTTPURLResponse(url: exchange.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: delivered)!
    deliver { client in
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty { client.urlProtocol(self, didLoad: data) }
      client.urlProtocolDidFinishLoading(self)
    }
  }

  private func fail(_ exchange: Exchange, _ error: any Error, source: String, fault: String?, answer: HarnessNetworkState.Answer) {
    exchange.state.log(method: exchange.method, url: exchange.url.absoluteString, status: nil, source: source, fault: fault,
      ms: exchange.elapsedMs, answer: answer)
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
