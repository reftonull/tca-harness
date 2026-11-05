import ComposableArchitecture
import Foundation
import TCAHarness

/// Bounded structural observation. App State need not conform to Codable.
public indirect enum HarnessValue: Codable, Equatable {
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
  public static func snapshot(_ state: Any, depth: Int = 7, budget: Int = 1800, redacting: Set<String> = ["token", "accessToken", "refreshToken", "password", "apiKey", "authorization"]) -> HarnessValue {
    var budget = budget
    let redacted = Set(redacting.map { $0.lowercased() })
    func visit(_ raw: Any, _ remaining: Int) -> HarnessValue {
      budget -= 1
      guard budget >= 0, remaining >= 0 else { return .string("<truncated>") }
      guard let value = unwrapState(raw) else { return .null }
      switch value {
      case let x as Bool: return .bool(x)
      case let x as String: return .string(String(x.prefix(500)))
      case let x as Int: return .number(Double(x))
      case let x as Double: return x.isFinite ? .number(x) : .string(String(x))
      case let x as Float: return x.isFinite ? .number(Double(x)) : .string(String(x))
      case let x as Date: return .string(ISO8601DateFormatter().string(from: x))
      case let x as UUID: return .string(x.uuidString)
      default: break
      }
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .class { return .string("<opaque \(String(describing: type(of: value)))>") }
      if mirror.displayStyle == .enum {
        guard let child = mirror.children.first else { return .string(String(describing: value)) }
        return .object(["case": .string(child.label ?? "unknown"), "value": visit(child.value, remaining - 1)])
      }
      if mirror.displayStyle == .dictionary {
        var entries: [String: HarnessValue] = [:]
        for pair in mirror.children.prefix(60) {
          let values = Array(Mirror(reflecting: pair.value).children)
          if values.count == 2 {
            let key = String(describing: values[0].value)
            entries[key] = redacted.contains(key.lowercased()) ? .string("<redacted>") : visit(values[1].value, remaining - 1)
          }
        }
        return .object(entries)
      }
      if let collection = value as? any Collection {
        return .array(collectionValues(collection).prefix(60).map { visit($0, remaining - 1) })
      }
      var result: [String: HarnessValue] = [:]
      for child in mirror.children.prefix(100) {
        guard let label = child.label, !label.contains("observationRegistrar") else { continue }
        let key = fieldName(label)
        result[key] = redacted.contains(key.lowercased()) ? .string("<redacted>") : visit(child.value, remaining - 1)
      }
      return result.isEmpty ? .string("<opaque \(String(describing: type(of: value)))>") : .object(result)
    }
    return visit(state, depth)
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
