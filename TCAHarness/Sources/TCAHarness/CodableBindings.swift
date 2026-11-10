import Foundation
import CoreFoundation
import TCAHarnessCore

@MainActor
public enum CodableBindings {
  /// Automatically enumerate primitive fields in an explicitly writable Codable group.
  static func offers<Value: Codable>(value: Value, prefix: String,
    numericRanges: [String: ClosedRange<Double>], send: @escaping (Value) -> Void) -> [HarnessOffer] {
    guard let data = try? JSONEncoder().encode(value),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
    let mirror = Mirror(reflecting: value)
    var result: [HarnessOffer] = []
    for key in object.keys.sorted() {
      let current = object[key]!
      func dispatch(_ replacement: Any) -> HarnessOperation {
        var copy = object
        copy[key] = replacement
        guard let data = try? JSONSerialization.data(withJSONObject: copy),
          let next = try? JSONDecoder().decode(Value.self, from: data) else { return .init { .failed } }
        send(next)
        return .completed
      }
      if let number = current as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        for desired in [false, true] where desired != number.boolValue {
          result.append(HarnessOffer(id: "\(prefix)/\(key)/\(desired)", feature: prefix,
            label: "Set \(key) to \(desired)") { dispatch(desired) })
        }
      } else if current is NSNumber {
        let range = numericRanges[key]
        result.append(HarnessOffer(id: "\(prefix)/\(key)", feature: prefix, label: "Set \(key) numeric value",
          arguments: NumberArgument.self,
          schema: HarnessArgumentSchema(.object(["value": range.map { .boundedNumber($0) } ?? .number])),
          validate: { argument in
            guard argument.value.isFinite,
              range?.contains(argument.value) ?? true else { throw HarnessArgumentError("Invalid value for \(key)") }
          }) { argument in dispatch(argument.value) })
      } else if let text = current as? String {
        let raw = mirror.children.first { fieldName($0.label ?? "") == key }?.value
        if let raw, let cases = Swift.type(of: raw) as? any CaseIterable.Type {
          for choice in enumChoices(cases) where choice != text {
            result.append(HarnessOffer(id: "\(prefix)/\(key)/\(choice)", feature: prefix,
              label: "Set \(key) to \(choice)") { dispatch(choice) })
          }
        } else {
          result.append(HarnessOffer(id: "\(prefix)/\(key)", feature: prefix, label: "Set \(key) text",
            arguments: TextArgument.self,
            schema: HarnessArgumentSchema(properties: ["value": HarnessStringField("New text for \(key)", maxLength: 1000)])) {
            dispatch($0.value)
          })
        }
      }
    }
    return result
  }
}

private func enumChoices<T: CaseIterable>(_ type: T.Type) -> [String] {
  T.allCases.compactMap { value in
    guard let encodable = value as? any Encodable,
      let data = try? JSONEncoder().encode(encodable) else { return nil }
    return try? JSONDecoder().decode(String.self, from: data)
  }
}

private struct NumberArgument: Decodable { let value: Double }
private struct TextArgument: Decodable { let value: String }
