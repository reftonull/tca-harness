import ComposableArchitecture
import Foundation
import TCAHarness

/// Bounded, read-only history of every action a store reduced, served to `tca devtools`.
/// Inert unless TCA_HARNESS=1, and always inert in builds compiled without `DEBUG`. The feature path only captures values; snapshots and diffs are
/// computed when a page is requested, so an unwatched timeline costs almost nothing.
///
/// TCA 2 has no per-action effect value, so entries carry no effect lifecycle. Mounted operations
/// are read from the live store just after each action, and agent-driven bindings (which send no
/// action) are recorded as `binding` entries.
public final class HarnessTimeline: @unchecked Sendable {
  /// What entries reveal about state and action payloads.
  public enum Detail: String, Sendable {
    /// State through the attached descriptor's observation, so `@HarnessIgnore`, explicit projections
    /// and credential redaction apply. Payloads keep their shape; values are replaced by their type.
    case projected
    /// All reflected state and payload values, minus credential-named fields. Use only when no
    /// state or action carries data that should stay out of a local debugging tool.
    case reflected
  }

  /// The default timeline used by `harnessTimeline()` and `store.harness(...)`.
  public static let shared = HarnessTimeline()

  /// Whether the timeline records. Always false in builds compiled without `DEBUG`.
  public let isEnabled: Bool
  /// Maximum number of retained entries; older entries are dropped.
  public let capacity: Int
  public let detail: Detail
  private let lock = NSLock()
  private let id = UUID().uuidString
  private let startedAt = Date()
  private let start = ContinuousClock.now
  private var records: [Record] = []
  private var dropped = 0
  private var nextIndex = 0
  private var sequence = 0
  private var attached = false
  // Non-nil while the harness dispatches; empty when the candidate is unknown.
  private var agent: String?
  private var observe: (@MainActor (Any) -> HarnessJSON?)?
  private var mounts: (@MainActor () -> [HarnessTimelineMount])?
  private var mountsScheduled = false
  // State before the action now being reduced; set by the leading half of the feature wrapper.
  private var reducing: (state: Any, began: ContinuousClock.Instant)?

  private struct Record {
    let index: Int
    var sequence: Int
    let timeMs: Double
    let reduceMs: Double
    let recordMs: Double
    let source: String
    let cause: Int?
    let candidateID: String?
    var effect: HarnessTimelineEffect?
    /// Overrides the reflected case path (synthetic entries).
    let path: [String]?
    var mounts: [HarnessTimelineMount]?
    /// Captured values, released once the entry is materialized. State is a value type, so
    /// retaining it shares storage; reference-typed fields are read when materialized.
    var captured: (action: Any, state: Any, previous: Any)?
    var entry: HarnessTimelineEntry?
  }

  /// - Parameter isEnabled: Defaults to `TCA_HARNESS=1`. Ignored (treated as false) in builds
  ///   compiled without `DEBUG`, where nothing can serve the timeline.
  public init(capacity: Int = 500, detail: Detail = .projected,
    isEnabled: Bool = ProcessInfo.processInfo.environment["TCA_HARNESS"] == "1") {
    self.capacity = max(capacity, 1)
    self.detail = detail
#if DEBUG
    self.isEnabled = isEnabled
#else
    self.isEnabled = false
#endif
  }

  /// Entries recorded or updated after `since`, oldest first, in bounded pages.
  /// Nil until a reducer records into this timeline.
  @MainActor
  public func page(since: Int, limit: Int = 40) -> HarnessTimelinePage? {
    guard locked({ attached }) else { return nil }
    materialize()
    lock.lock(); defer { lock.unlock() }
    let pending = records.filter { $0.sequence > since }.sorted { $0.sequence < $1.sequence }
    let page = pending.prefix(limit).compactMap { record -> HarnessTimelineEntry? in
      guard var entry = record.entry else { return nil }
      entry.sequence = record.sequence; entry.effect = record.effect
      return entry
    }
    let hasMore = pending.count > limit
    return HarnessTimelinePage(timelineID: id, startedAt: ISO8601DateFormatter().string(from: startedAt),
      capacity: capacity, detail: detail.rawValue, dropped: dropped,
      sequence: hasMore ? pending[limit - 1].sequence : sequence, hasMore: hasMore, entries: page)
  }

  func markAttached() {
    lock.lock(); attached = true; lock.unlock()
  }

  func setReaders(observe: @escaping @MainActor (Any) -> HarnessJSON?,
    mounts: @escaping @MainActor () -> [HarnessTimelineMount]) {
    lock.lock(); self.observe = observe; self.mounts = mounts; lock.unlock()
  }

  /// Actions sent inside `body` are attributed to the agent and, when given, the candidate.
  func asAgent<T>(_ candidate: String?, _ body: () throws -> T) rethrows -> T {
    lock.lock(); let outer = agent; agent = candidate ?? outer ?? ""; lock.unlock()
    defer { lock.lock(); agent = outer; lock.unlock() }
    return try body()
  }

  func willReduce(_ state: Any) {
    lock.lock(); reducing = (state, ContinuousClock.now); lock.unlock()
  }

  func didReduce(_ action: Any, _ state: Any) {
    let reducing = locked { defer { self.reducing = nil }; return self.reducing }
    guard let reducing else { return }
    record(action: action, state: state, previous: reducing.state, reduceDuration: ContinuousClock.now - reducing.began)
  }

  /// A state write with no action, such as an agent-driven binding or dismissal.
  func recordWrite(path: [String], state: Any, previous: Any) {
    record(action: path, state: state, previous: previous, reduceDuration: .zero, path: path)
  }

  /// Index the next recorded entry will receive.
  var currentIndex: Int { locked { nextIndex } }

  private func record(action: Any, state: Any, previous: Any, reduceDuration: Duration, path: [String]? = nil) {
    let began = ContinuousClock.now
    lock.lock(); defer { lock.unlock() }
    var source = "app", candidate: String?
    if let agent {
      source = "agent"; candidate = agent.isEmpty ? nil : agent
    }
    sequence += 1
    let index = nextIndex
    nextIndex += 1
    let now = ContinuousClock.now
    records.append(Record(index: index, sequence: sequence, timeMs: milliseconds(now - start),
      reduceMs: milliseconds(reduceDuration), recordMs: milliseconds(now - began), source: source,
      cause: nil, candidateID: candidate, effect: nil, path: path, mounts: nil, captured: (action, state, previous)))
    if records.count > capacity {
      dropped += records.count - capacity
      records.removeFirst(records.count - capacity)
    }
    // Read mounted features once the store has settled; one read covers a burst of actions.
    if mounts != nil, !mountsScheduled {
      mountsScheduled = true
      Task { @MainActor [weak self] in self?.captureMounts() }
    }
  }

  @MainActor
  private func captureMounts() {
    guard let read = locked({ mountsScheduled = false; return mounts }) else { return }
    let current = read()
    lock.lock(); defer { lock.unlock() }
    for offset in records.indices where records[offset].mounts == nil { records[offset].mounts = current }
  }

  /// Snapshots captured records in index order, diffing each against the state it started from.
  /// TCA 2 can change state between actions (bindings, `store.modify`), so the previous entry's
  /// state isn't necessarily where this one began.
  @MainActor
  private func materialize() {
    let (pending, observe) = locked {
      (records.filter { $0.entry == nil }, self.observe)
    }
    guard !pending.isEmpty else { return }
    var built: [(Int, HarnessTimelineEntry)] = []
    for record in pending {
      guard let captured = record.captured else { continue }
      let began = ContinuousClock.now
      let state = snapshot(captured.state, observe)
      let before = snapshot(captured.previous, observe)
      var changes: [String] = []
      if before != .null, state != .null { collectChanges(before, state, "", &changes) }
      let entry = HarnessTimelineEntry(index: record.index, sequence: record.sequence, timeMs: record.timeMs,
        reduceMs: record.reduceMs, recordMs: record.recordMs, snapshotMs: 0, action: record.path ?? actionPath(captured.action),
        payload: detail == .reflected ? StateInspection.snapshot(captured.action, depth: 8)
          : payloadShape(captured.action, depth: 8), source: record.source, cause: record.cause,
        candidateID: record.candidateID, state: state, truncated: containsTruncation(state), changes: changes,
        effect: record.effect, mounts: record.mounts)
      built.append((record.index, entry.withSnapshotMs(milliseconds(ContinuousClock.now - began))))
    }
    lock.lock(); defer { lock.unlock() }
    guard let first = records.first?.index else { return }
    for (index, entry) in built where index >= first && index - first < records.count {
      records[index - first].entry = entry
      records[index - first].captured = nil
    }
  }

  /// Without an attached descriptor a projected timeline records no state.
  @MainActor
  private func snapshot(_ state: Any, _ observe: (@MainActor (Any) -> HarnessJSON?)?) -> HarnessJSON {
    if detail == .reflected { return StateInspection.snapshot(state, depth: 12) }
    return observe?(state) ?? .null
  }

  private func locked<T>(_ read: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return read()
  }
}

extension FeatureProtocol {
  /// Records every action for `tca devtools`. Apply to the root feature so all actions pass through it.
  /// A pass-through unless the timeline is enabled (`TCA_HARNESS=1` in a `DEBUG` build).
  public func harnessTimeline(_ timeline: HarnessTimeline = .shared) -> HarnessTimelineFeature<Self> {
    if timeline.isEnabled { timeline.markAttached() }
    return HarnessTimelineFeature(base: self, timeline: timeline)
  }
}

/// Captures state on either side of the base feature. Children run inside `base`, so a child's
/// action is recorded once, at the root, with the root state it produced.
public struct HarnessTimelineFeature<Base: FeatureProtocol>: FeatureProtocol {
  public typealias State = Base.State
  public typealias Action = Base.Action
  let base: Base
  let timeline: HarnessTimeline

  public var body: some FeatureProtocol<State, Action> {
    if timeline.isEnabled {
      Update { [timeline] state, _ in timeline.willReduce(state) }
      base
      Update { [timeline] state, action in timeline.didReduce(action, state) }
    } else {
      base
    }
  }
}

/// Enum case path of an action, descending through identified and stack elements.
func actionPath(_ action: Any) -> [String] {
  var path: [String] = []
  var current = action
  while path.count < 16 {
    let mirror = Mirror(reflecting: current)
    guard mirror.displayStyle == .enum else { break }
    guard let child = mirror.children.first else {
      path.append(enumCaseName(current)); break
    }
    let payload = Mirror(reflecting: child.value)
    if payload.displayStyle == .tuple, let element = payload.children.first(where: { $0.label == "action" }) {
      let id = payload.children.first(where: { $0.label == "id" }).map { String(describing: $0.value) }
      path.append(id.map { "[\($0.prefix(40))]" } ?? (child.label ?? "?"))
      current = element.value
      continue
    }
    path.append(child.label ?? "?")
    current = child.value
  }
  return path
}

/// Name of a payload-free enum case. A custom description could print anything, so such enums
/// show only their type.
func enumCaseName(_ value: Any) -> String {
  value is CustomStringConvertible || value is CustomDebugStringConvertible
    ? "<\(type(of: value))>" : String(describing: value)
}

/// Payload structure without values: enum case names and field names are kept, every other value
/// becomes its type. Built from the value itself so a field or key named `case` is never mistaken for one.
func payloadShape(_ value: Any, depth: Int) -> HarnessJSON {
  guard depth > 0 else { return .string("<truncated>") }
  guard let value = unwrapState(value) else { return .null }
  let mirror = Mirror(reflecting: value)
  switch mirror.displayStyle {
  case .enum:
    guard let child = mirror.children.first else { return .object(["case": .string(enumCaseName(value))]) }
    return .object(["case": .string(child.label ?? "?"), "value": payloadShape(child.value, depth: depth - 1)])
  case .struct, .tuple:
    var fields: [String: HarnessJSON] = [:]
    for (offset, child) in mirror.children.prefix(100).enumerated() {
      fields[child.label.map(fieldName) ?? ".\(offset)"] = payloadShape(child.value, depth: depth - 1)
    }
    return fields.isEmpty ? .string("<\(type(of: value))>") : .object(fields)
  case .collection, .set:
    return .array(mirror.children.prefix(20).map { payloadShape($0.value, depth: depth - 1) })
  default:
    // Scalars, dictionaries (keys can be data) and classes keep only their type.
    return .string("<\(type(of: value))>")
  }
}

func containsTruncation(_ value: HarnessJSON) -> Bool {
  switch value {
  case let .object(fields): fields.values.contains(where: containsTruncation)
  case let .array(items): items.contains(where: containsTruncation)
  case let .string(text): text == "<truncated>"
  default: false
  }
}

func collectChanges(_ old: HarnessJSON, _ new: HarnessJSON, _ prefix: String, _ out: inout [String]) {
  guard old != new, out.count < 200 else { return }
  switch (old, new) {
  case let (.object(a), .object(b)):
    for key in Set(a.keys).union(b.keys).sorted() {
      let path = prefix.isEmpty ? key : prefix + "." + key
      collectChanges(a[key] ?? .null, b[key] ?? .null, path, &out)
    }
  case let (.array(a), .array(b)) where a.count == b.count:
    for (offset, pair) in zip(a, b).enumerated() {
      collectChanges(pair.0, pair.1, prefix + "[\(offset)]", &out)
    }
  default:
    out.append(prefix.isEmpty ? "(root)" : prefix)
  }
}

private func milliseconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return (Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15).rounded(toPlaces: 3)
}

private extension Double {
  func rounded(toPlaces places: Int) -> Double {
    let scale = pow(10, Double(places)); return (self * scale).rounded() / scale
  }
}
