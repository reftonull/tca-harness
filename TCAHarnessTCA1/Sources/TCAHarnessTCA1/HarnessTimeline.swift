import ComposableArchitecture
import Foundation
import TCAHarness

/// Bounded, read-only history of every action a store reduced, served to `tca devtools`.
/// Inert unless TCA_HARNESS=1, and always inert in builds compiled without `DEBUG`. The reducer path only captures values; snapshots, diffs and
/// mounts are computed when a page is requested, so an unwatched timeline costs almost nothing.
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
  private var lastSnapshot: (index: Int, state: HarnessJSON)?
  private var attached = false
  // Non-nil while the harness dispatches; empty when the candidate is unknown.
  private var agent: String?
  private var pendingEffectActions: [(cause: Int, key: Int, at: ContinuousClock.Instant)] = []
  private var observe: (@MainActor (Any) -> HarnessJSON?)?
  private var mounts: (@MainActor (Any) -> [HarnessTimelineMount]?)?
  /// The action being reduced, or the last one reduced; names the `action` of recorded issues.
  private var currentAction: Any?
  private var afterReduce: (@MainActor (Any) -> Void)?

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
    mounts: @escaping @MainActor (Any) -> [HarnessTimelineMount]?) {
    lock.lock(); self.observe = observe; self.mounts = mounts; lock.unlock()
  }

  /// Called on the main actor with the new state after each reduced action, e.g. to check invariants.
  func setAfterReduce(_ body: (@MainActor (Any) -> Void)?) {
    lock.lock(); afterReduce = body; lock.unlock()
  }

  /// Case path of the action being reduced, or of the last one reduced, joined with dots (e.g. `shelf.deleteResponse`).
  public var currentActionPath: String? {
    guard let action = locked({ currentAction }) else { return nil }
    return actionPath(action).joined(separator: ".")
  }

  func willReduce(_ action: Any) {
    lock.lock(); currentAction = action; lock.unlock()
  }

  func didReduce(_ state: Any) {
    guard let afterReduce = locked({ afterReduce }), Thread.isMainThread else { return }
    // TCA 1 stores reduce on the main actor; the value never leaves this thread.
    let box = UncheckedBox(state)
    MainActor.assumeIsolated { afterReduce(box.value) }
  }

  /// Actions sent inside `body` are attributed to the agent and, when given, the candidate.
  func asAgent<T>(_ candidate: String?, _ body: () throws -> T) rethrows -> T {
    lock.lock(); let outer = agent; agent = candidate ?? outer ?? ""; lock.unlock()
    defer { lock.lock(); agent = outer; lock.unlock() }
    return try body()
  }

  func record(action: Any, state: Any, previous: Any, reduceDuration: Duration, hasEffect: Bool) -> Int {
    let began = ContinuousClock.now
    // Describing a large action is costly; only needed when an effect send is pending.
    let key = locked { pendingEffectActions.isEmpty } ? nil : actionKey(action)
    lock.lock(); defer { lock.unlock() }
    var source = "app", cause: Int?, candidate: String?
    // An effect's mapped send runs immediately before the store enqueues that action, and the store
    // reduces in enqueue order, so the first pending effect action with the same description is this one.
    pendingEffectActions.removeAll { began - $0.at > .seconds(2) }
    if let key, let match = pendingEffectActions.firstIndex(where: { $0.key == key }) {
      source = "effect"; cause = pendingEffectActions[match].cause; pendingEffectActions.remove(at: match)
    } else if let agent {
      source = "agent"; candidate = agent.isEmpty ? nil : agent
    }
    sequence += 1
    let index = nextIndex
    nextIndex += 1
    let now = ContinuousClock.now
    records.append(Record(index: index, sequence: sequence, timeMs: milliseconds(now - start),
      reduceMs: milliseconds(reduceDuration), recordMs: milliseconds(now - began), source: source,
      cause: cause, candidateID: candidate, effect: hasEffect ? HarnessTimelineEffect(status: "running") : nil,
      captured: (action, state, previous)))
    if records.count > capacity {
      dropped += records.count - capacity
      records.removeFirst(records.count - capacity)
    }
    return index
  }

  func noteEffectAction(_ action: Any, cause: Int) {
    let key = actionKey(action)
    lock.lock(); defer { lock.unlock() }
    pendingEffectActions.append((cause, key, ContinuousClock.now))
    if pendingEffectActions.count > 256 { pendingEffectActions.removeFirst(pendingEffectActions.count - 256) }
  }

  func effectEnded(_ index: Int, cancelled: Bool) {
    let elapsed = milliseconds(ContinuousClock.now - start)
    lock.lock(); defer { lock.unlock() }
    guard let first = records.first?.index, index >= first, index - first < records.count else { return }
    sequence += 1
    records[index - first].effect = HarnessTimelineEffect(status: cancelled ? "cancelled" : "ended", endedMs: elapsed)
    records[index - first].sequence = sequence
  }

  /// Snapshots captured records in index order, diffing each against its predecessor.
  @MainActor
  private func materialize() {
    let (pending, observe, mounts) = locked {
      (records.filter { $0.entry == nil }, self.observe, self.mounts)
    }
    guard !pending.isEmpty else { return }
    var previous = locked { lastSnapshot }
    var built: [(Int, HarnessTimelineEntry)] = []
    for record in pending {
      guard let captured = record.captured else { continue }
      let began = ContinuousClock.now
      let state = snapshot(captured.state, observe)
      let before = previous?.index == record.index - 1 ? previous!.state : snapshot(captured.previous, observe)
      var changes: [String] = []
      if before != .null, state != .null { collectChanges(before, state, "", &changes) }
      let entry = HarnessTimelineEntry(index: record.index, sequence: record.sequence, timeMs: record.timeMs,
        reduceMs: record.reduceMs, recordMs: record.recordMs, snapshotMs: 0, action: actionPath(captured.action),
        payload: detail == .reflected ? StateInspection.snapshot(captured.action, depth: 8, budget: 400).json
          : payloadShape(captured.action, depth: 8), source: record.source, cause: record.cause,
        candidateID: record.candidateID, state: state, truncated: containsTruncation(state), changes: changes,
        effect: record.effect, mounts: mounts?(captured.state))
      built.append((record.index, entry.withSnapshotMs(milliseconds(ContinuousClock.now - began))))
      previous = (record.index, state)
    }
    lock.lock(); defer { lock.unlock() }
    lastSnapshot = previous
    guard let first = records.first?.index else { return }
    for (index, entry) in built where index >= first && index - first < records.count {
      records[index - first].entry = entry
      records[index - first].captured = nil
    }
  }

  /// Without an attached descriptor a projected timeline records no state.
  @MainActor
  private func snapshot(_ state: Any, _ observe: (@MainActor (Any) -> HarnessJSON?)?) -> HarnessJSON {
    if detail == .reflected { return StateInspection.snapshot(state, depth: 12, budget: 8000).json }
    return observe?(state) ?? .null
  }

  private func locked<T>(_ read: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return read()
  }
}

extension Reducer {
  /// Records every action for `tca devtools`. Apply to the root reducer so all actions pass through it.
  /// A pass-through unless the timeline is enabled (`TCA_HARNESS=1` in a `DEBUG` build).
  public func harnessTimeline(_ timeline: HarnessTimeline = .shared) -> _HarnessTimelineReducer<Self> {
    if timeline.isEnabled { timeline.markAttached() }
    return _HarnessTimelineReducer(base: self, timeline: timeline)
  }
}

public struct _HarnessTimelineReducer<Base: Reducer>: Reducer {
  let base: Base
  let timeline: HarnessTimeline

  public func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
    guard timeline.isEnabled else { return base.reduce(into: &state, action: action) }
    let previous = state
    timeline.willReduce(action)
    let began = ContinuousClock.now
    let effect = base.reduce(into: &state, action: action)
    let duration = ContinuousClock.now - began
    let running = !effect.isNone
    let index = timeline.record(action: action, state: state, previous: previous,
      reduceDuration: duration, hasEffect: running)
    timeline.didReduce(state)
    guard running else { return effect }
    let timeline = timeline
    // Cancellation by an inner id ends the inner effect; that is reported as `ended`.
    return effect
      .map { action in timeline.noteEffectAction(action, cause: index); return action }
      .concatenate(with: .run { _ in timeline.effectEnded(index, cancelled: Task.isCancelled) })
  }
}

extension Effect {
  var isNone: Bool {
    guard let operation = Mirror(reflecting: self).children.first(where: { $0.label == "operation" })
    else { return false }
    return String(describing: operation.value) == "none"
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

/// Identity of an action, used to match an effect's send to the reduced action. Actions need not be
/// Equatable, so this compares descriptions; values that print the same are indistinguishable.
func actionKey(_ action: Any) -> Int {
  var hasher = Hasher()
  hasher.combine(String(describing: action))
  return hasher.finalize()
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

private struct UncheckedBox: @unchecked Sendable {
  let value: Any
  init(_ value: Any) { self.value = value }
}
