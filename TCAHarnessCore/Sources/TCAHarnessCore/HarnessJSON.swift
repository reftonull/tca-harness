import Foundation

/// The wire representation of typed operation arguments.
public indirect enum HarnessJSON: Codable, Equatable, Sendable {
  case object([String: HarnessJSON]), array([HarnessJSON]), string(String), number(Double), bool(Bool), null

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let x = try? c.decode(Bool.self) { self = .bool(x) }
    else if let x = try? c.decode(String.self) { self = .string(x) }
    else if let x = try? c.decode(Double.self) { self = .number(x) }
    else if let x = try? c.decode([HarnessJSON].self) { self = .array(x) }
    else { self = .object(try c.decode([String: HarnessJSON].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case let .object(x): try c.encode(x)
    case let .array(x): try c.encode(x)
    case let .string(x): try c.encode(x)
    case let .number(x): try c.encode(x)
    case let .bool(x): try c.encode(x)
    case .null: try c.encodeNil()
    }
  }
}

public protocol HarnessInput: Codable {
  static var harnessSchema: HarnessJSONSchema { get }
}

/// A deliberately supported JSON Schema subset, validated before typed decoding.
public indirect enum HarnessJSONSchema: Codable, Equatable, Sendable {
  case string(description: String = "", choices: [String]? = nil, minLength: Int? = nil, maxLength: Int? = nil)
  case number, integer, boolean
  case boundedNumber(ClosedRange<Double>)
  case object([String: HarnessJSONSchema])
  case array(HarnessJSONSchema)
  case nullable(HarnessJSONSchema)

  private enum Keys: String, CodingKey { case type, description, properties, required, additionalProperties, items, anyOf, minLength, maxLength, minimum, maximum; case choices = "enum" }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    if let variants = try c.decodeIfPresent([HarnessJSONSchema].self, forKey: .anyOf), let first = variants.first {
      self = .nullable(first); return
    }
    switch try c.decode(String.self, forKey: .type) {
    case "string": self = .string(description: try c.decodeIfPresent(String.self, forKey: .description) ?? "", choices: try c.decodeIfPresent([String].self, forKey: .choices), minLength: try c.decodeIfPresent(Int.self, forKey: .minLength), maxLength: try c.decodeIfPresent(Int.self, forKey: .maxLength))
    case "number":
      if let minimum = try c.decodeIfPresent(Double.self, forKey: .minimum), let maximum = try c.decodeIfPresent(Double.self, forKey: .maximum), minimum <= maximum {
        self = .boundedNumber(minimum...maximum)
      } else { self = .number }
    case "integer": self = .integer
    case "boolean": self = .boolean
    case "object": self = .object(try c.decode([String: HarnessJSONSchema].self, forKey: .properties))
    case "array": self = .array(try c.decode(HarnessJSONSchema.self, forKey: .items))
    case "null": self = .nullable(.string()) // Only used in the second arm of generated anyOf.
    default: throw HarnessArgumentError("Unsupported schema type")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    switch self {
    case let .string(description, choices, minimum, maximum):
      try c.encode("string", forKey: .type)
      if !description.isEmpty { try c.encode(description, forKey: .description) }
      try c.encodeIfPresent(choices, forKey: .choices)
      try c.encodeIfPresent(minimum, forKey: .minLength)
      try c.encodeIfPresent(maximum, forKey: .maxLength)
    case .number: try c.encode("number", forKey: .type)
    case let .boundedNumber(range):
      try c.encode("number", forKey: .type)
      try c.encode(range.lowerBound, forKey: .minimum)
      try c.encode(range.upperBound, forKey: .maximum)
    case .integer: try c.encode("integer", forKey: .type)
    case .boolean: try c.encode("boolean", forKey: .type)
    case let .object(properties):
      try c.encode("object", forKey: .type)
      try c.encode(properties, forKey: .properties)
      try c.encode(properties.keys.sorted(), forKey: .required)
      try c.encode(false, forKey: .additionalProperties)
    case let .array(items):
      try c.encode("array", forKey: .type); try c.encode(items, forKey: .items)
    case let .nullable(schema):
      var variants = c.nestedUnkeyedContainer(forKey: .anyOf)
      try variants.encode(schema)
      var null = variants.nestedContainer(keyedBy: Keys.self)
      try null.encode("null", forKey: .type)
    }
  }

  public func validate(_ value: HarnessJSON, path: String = "arguments") throws {
    switch (self, value) {
    case let (.string(_, choices, minimum, maximum), .string(text)):
      guard choices?.contains(text) ?? true else { throw HarnessArgumentError("\(path): invalid choice") }
      if let minimum, text.unicodeScalars.count < minimum { throw HarnessArgumentError("\(path): too short") }
      if let maximum, text.unicodeScalars.count > maximum { throw HarnessArgumentError("\(path): too long") }
    case (.number, .number(let n)) where n.isFinite: break
    case let (.boundedNumber(range), .number(n)) where n.isFinite && range.contains(n): break
    case (.integer, .number(let n)) where n.isFinite && n.rounded() == n: break
    case (.boolean, .bool): break
    case let (.object(properties), .object(values)):
      guard Set(values.keys) == Set(properties.keys) else { throw HarnessArgumentError("\(path): fields must match schema") }
      for (key, schema) in properties { try schema.validate(values[key]!, path: "\(path).\(key)") }
    case let (.array(schema), .array(values)):
      guard values.count <= 1000 else { throw HarnessArgumentError("\(path): array exceeds 1000 items") }
      for (index, element) in values.enumerated() { try schema.validate(element, path: "\(path)[\(index)]") }
    case (.nullable, .null): break
    case let (.nullable(schema), value): try schema.validate(value, path: path)
    default: throw HarnessArgumentError("\(path): wrong JSON type")
    }
  }
}

extension String: HarnessInput { public static var harnessSchema: HarnessJSONSchema { .string() } }
extension Bool: HarnessInput { public static var harnessSchema: HarnessJSONSchema { .boolean } }
extension Int: HarnessInput { public static var harnessSchema: HarnessJSONSchema { .integer } }
extension Double: HarnessInput { public static var harnessSchema: HarnessJSONSchema { .number } }
extension Float: HarnessInput { public static var harnessSchema: HarnessJSONSchema { .number } }
extension Optional: HarnessInput where Wrapped: HarnessInput {
  public static var harnessSchema: HarnessJSONSchema { .nullable(Wrapped.harnessSchema) }
}
extension Array: HarnessInput where Element: HarnessInput {
  public static var harnessSchema: HarnessJSONSchema { .array(Element.harnessSchema) }
}
