import Foundation

/// Convenience constructor for a constrained text field in a typed JSON schema.
public struct HarnessStringField: Sendable {
  let schema: HarnessJSONSchema
  public init(_ description: String, choices: [String]? = nil, minLength: Int? = nil, maxLength: Int? = nil) {
    schema = .string(description: description, choices: choices, minLength: minLength, maxLength: maxLength)
  }
}

/// One schema representation is shared by generated inputs and explicit adapters.
public struct HarnessArgumentSchema: Codable, Sendable {
  public let value: HarnessJSONSchema
  public init(_ schema: HarnessJSONSchema) { value = schema }
  public init(properties: [String: HarnessStringField]) { value = .object(properties.mapValues(\.schema)) }
  public init(from decoder: Decoder) throws { value = try HarnessJSONSchema(from: decoder) }
  public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
  func validate(_ values: [String: HarnessJSON]) throws { try value.validate(.object(values)) }
}

public struct HarnessArgumentError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
