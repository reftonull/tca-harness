import ComposableArchitecture
import Foundation
import TCAHarness

/// Bounded structural observation. App State need not conform to Codable.
public indirect enum HarnessValue: Codable, Equatable, Sendable {
  case object([String: HarnessValue])
  case array([HarnessValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([HarnessValue].self) { self = .array(v) }
    else { self = .object(try c.decode([String: HarnessValue].self)) }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case let .object(v): try c.encode(v)
    case let .array(v): try c.encode(v)
    case let .string(v): try c.encode(v)
    case let .number(v): try c.encode(v)
    case let .bool(v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
}

protocol StateWrapper { var inspectedWrappedValue: Any? { get } }

/// A value that supplies its own snapshot when reached by reflection, such as `Hosted.State`, whose
/// model would otherwise be an opaque reference.
protocol HarnessSnapshotProviding { var harnessSnapshot: HarnessValue { get } }

enum HarnessSnapshotContext {
  /// True while the timeline snapshots captured states. State holding a reference (a hosted model)
  /// then answers with what it recorded at reduce time, not the object's current values.
  @TaskLocal static var recorded = false
}

/// Closures are behavior, not state: a model's injected client (`struct API { var fetch: () async
/// throws -> T }`) is left out of its snapshot instead of filling it with opaque entries.
private func isFunction(_ value: Any, _ mirror: Mirror) -> Bool {
  mirror.displayStyle == nil && mirror.children.isEmpty && String(describing: type(of: value)).contains("->")
}
extension PresentationState: StateWrapper {
  var inspectedWrappedValue: Any? { wrappedValue }
}

func unwrapState(_ value: Any) -> Any? {
  if let wrapper = value as? StateWrapper { return wrapper.inspectedWrappedValue.flatMap(unwrapState) }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .optional { return mirror.children.first.flatMap { unwrapState($0.value) } }
  return value
}

func fieldName(_ name: String) -> String {
  // ObservableState stores ordinary properties with one leading underscore.
  name.hasPrefix("_") ? String(name.dropFirst()) : name
}

func stateAtPath(_ root: Any, _ path: [String]) -> Any? {
  guard let value = unwrapState(root) else { return nil }
  guard let first = path.first else { return value }
  let mirror = Mirror(reflecting: value)
  guard let child = mirror.children.first(where: { fieldName($0.label ?? "") == first }) else { return nil }
  return stateAtPath(child.value, Array(path.dropFirst()))
}

public enum StateInspection {
  /// A bounded structural snapshot of `state`. Class instances are opaque unless `reflectingObjects`
  /// is set, which reads their stored properties (as for `@Observable` models), once per object.
  public static func snapshot(_ state: Any, depth: Int = 7, budget: Int = 1800, redacting: Set<String> = ["token", "accessToken", "refreshToken", "password", "apiKey", "authorization"],
    reflectingObjects: Bool = false) -> HarnessValue {
    var budget = budget
    var visited = Set<ObjectIdentifier>()
    let redacted = Set(redacting.map { $0.lowercased() })
    // nil means "leave this field out": a closure, or a struct made only of closures.
    func visit(_ raw: Any, _ remaining: Int) -> HarnessValue? {
      budget -= 1
      guard budget >= 0, remaining >= 0 else { return .string("<truncated>") }
      guard let value = unwrapState(raw) else { return .null }
      if let provider = value as? HarnessSnapshotProviding { return provider.harnessSnapshot }
      switch value {
      case let x as Bool: return .bool(x)
      case let x as String: return .string(String(x.prefix(500)))
      case let x as Int: return .number(Double(x))
      case let x as Double: return x.isFinite ? .number(x) : .string(String(x))
      case let x as Float: return x.isFinite ? .number(Double(x)) : .string(String(x))
      case let x as Date:
        // Milliseconds, so two different instants within the same second still differ.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: x))
      case let x as UUID: return .string(x.uuidString)
      default: break
      }
      let mirror = Mirror(reflecting: value)
      if isFunction(value, mirror) { return nil }
      if mirror.displayStyle == .class {
        guard reflectingObjects else { return .string("<opaque \(String(describing: type(of: value)))>") }
        guard visited.insert(ObjectIdentifier(value as AnyObject)).inserted else {
          return .string("<cycle \(String(describing: type(of: value)))>")
        }
      }
      if mirror.displayStyle == .enum {
        guard let child = mirror.children.first else { return .string(String(describing: value)) }
        return .object(["case": .string(child.label ?? "unknown"), "value": visit(child.value, remaining - 1) ?? .null])
      }
      if mirror.displayStyle == .dictionary {
        var entries: [String: HarnessValue] = [:]
        for pair in mirror.children.prefix(60) {
          let values = Array(Mirror(reflecting: pair.value).children)
          if values.count == 2 {
            let key = String(describing: values[0].value)
            entries[key] = redacted.contains(key.lowercased()) ? .string("<redacted>") : visit(values[1].value, remaining - 1) ?? .null
          }
        }
        return .object(entries)
      }
      if let collection = value as? any Collection {
        return .array(collectionValues(collection).prefix(60).map { visit($0, remaining - 1) ?? .null })
      }
      var result: [String: HarnessValue] = [:]
      var omitted = 0
      for child in mirror.children.prefix(100) {
        // Skip macro bookkeeping such as `_$observationRegistrar`.
        guard let label = child.label, !label.contains("observationRegistrar"), !label.hasPrefix("_$") else { continue }
        let key = fieldName(label)
        if redacted.contains(key.lowercased()) { result[key] = .string("<redacted>"); continue }
        if let field = visit(child.value, remaining - 1) { result[key] = field } else { omitted += 1 }
      }
      if result.isEmpty && omitted > 0 { return nil }
      return result.isEmpty ? .string("<opaque \(String(describing: type(of: value)))>") : .object(result)
    }
    return visit(state, depth) ?? .null
  }
}

extension HarnessValue {
  /// The transport-level representation of the same structure.
  public var json: HarnessJSON {
    switch self {
    case let .object(v): .object(v.mapValues(\.json))
    case let .array(v): .array(v.map(\.json))
    case let .string(v): .string(v)
    case let .number(v): .number(v)
    case let .bool(v): .bool(v)
    case .null: .null
    }
  }
}

private func collectionValues<C: Collection>(_ value: C) -> [Any] { value.prefix(60).map { $0 as Any } }
