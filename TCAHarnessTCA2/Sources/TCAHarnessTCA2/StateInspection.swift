import ComposableArchitecture
import Foundation
import TCAHarness

/// Bounded structural observation. App state need not conform to Codable.
public typealias HarnessValue = HarnessJSON

/// Conform a property wrapper or container so snapshots read its value instead of its storage.
///
/// Generated snapshots read state fields through their accessors (`state.projects`), which
/// already unwraps wrappers such as SQLiteData's `@Fetch`/`@FetchAll`. This hook is for values
/// reached by reflection deeper in the tree.
public protocol HarnessInspectable {
  var harnessInspectedValue: Any? { get }
}

extension Spawn: HarnessInspectable {
  public var harnessInspectedValue: Any? { state }
}

extension StoreTaskID: HarnessInspectable {
  public var harnessInspectedValue: Any? { ["isRunning": isRunning] }
}

func unwrapState(_ value: Any) -> Any? {
  if let wrapper = value as? HarnessInspectable { return wrapper.harnessInspectedValue.flatMap(unwrapState) }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .optional { return mirror.children.first.flatMap { unwrapState($0.value) } }
  return value
}

func fieldName(_ name: String) -> String {
  // Observation-tracked state and property wrappers store fields with one leading underscore.
  name.hasPrefix("_") ? String(name.dropFirst()) : name
}

public enum StateInspection {
  public static let sensitiveFields: Set<String> = ["token", "accesstoken", "refreshtoken", "password", "apikey", "authorization"]

  public static func snapshot(_ state: Any, depth: Int = 7, redacting: Set<String> = sensitiveFields) -> HarnessValue {
    var budget = 1800
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
      case let x as URL: return .string(x.absoluteString)
      case let x as any RawRepresentable<String>: return .string(x.rawValue)
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
            let key = String(describing: unwrapState(values[0].value) ?? "nil")
            entries[key] = redacted.contains(key.lowercased()) ? .string("<redacted>") : visit(values[1].value, remaining - 1)
          }
        }
        return .object(entries)
      }
      if let collection = value as? any Collection {
        return .array(collectionValues(collection).map { visit($0, remaining - 1) })
      }
      var result: [String: HarnessValue] = [:]
      for child in mirror.children.prefix(100) {
        // Skip observation registrars and macro bookkeeping such as `_$valueLocation`.
        guard let label = child.label, !label.hasPrefix("_$"), !label.contains("observationRegistrar") else { continue }
        let key = fieldName(label)
        result[key] = redacted.contains(key.lowercased()) ? .string("<redacted>") : visit(child.value, remaining - 1)
      }
      return result.isEmpty ? .string("<opaque \(String(describing: type(of: value)))>") : .object(result)
    }
    return visit(state, depth)
  }
}

private func collectionValues<C: Collection>(_ value: C) -> [Any] { value.prefix(60).map { $0 as Any } }
