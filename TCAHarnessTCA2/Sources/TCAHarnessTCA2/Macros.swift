import Foundation
import TCAHarness

/// Generate a descriptor for a `@Feature struct` or `@Feature enum` from its source as written.
///
/// Struct features: no-payload `…Tapped` actions are exposed by convention; other actions opt in
/// with `@HarnessOperation`. State fields that match an action case (`Scope`/`ifLet`/`forEach`
/// and stack paths) and `Spawn<Child>` fields become child features; `@HarnessBinding` fields
/// become typed setters. Enum features (destinations, stack paths) mount each feature case.
///
/// - Parameter dismiss: A label for closing this feature while it's presented, as the back button
///   or a swipe does (`store.dismiss()`). Omit it for features that close only through their own
///   actions, such as a confirmation.
@attached(member, names: named(harnessDescriptor))
@attached(extension, conformances: HarnessFeatureProvider)
public macro HarnessFeature(dismiss: String? = nil) = #externalMacro(module: "HarnessMacrosTCA2Plugin", type: "HarnessFeatureMacro")

/// Opt an action into discovery.
///
/// - Parameters:
///   - label: A human-readable label. Defaults to the case name.
///   - available: A `Bool` key path on `State`, written with an explicit root (`\State.canSave`).
///   - choices: A `[HarnessChoice<Value>]` key path on `State`. The first payload is chosen from
///     it, so each current choice becomes its own candidate. A second payload, if present, is a
///     typed argument.
///   - completion: `.effects` (default) waits for the tasks started by the action; `.dispatch`
///     succeeds as soon as the action is sent.
@attached(peer)
public macro HarnessOperation(
  _ label: String? = nil,
  available: AnyKeyPath? = nil,
  choices: AnyKeyPath? = nil,
  completion: HarnessCompletion = .effects
) = #externalMacro(module: "HarnessMacrosTCA2Plugin", type: "MarkerMacro")

/// Exclude a case or stored field from generated metadata.
@attached(peer)
public macro HarnessIgnore() = #externalMacro(module: "HarnessMacrosTCA2Plugin", type: "MarkerMacro")

/// Expose a writable state field as a typed setter that writes through the store, like a
/// SwiftUI binding (`$store.name`). The field's type must conform to `HarnessInput`. `Bool` and
/// `String`-backed `CaseIterable` fields offer one argument-free candidate per other value.
@attached(peer)
public macro HarnessBinding(_ label: String? = nil, available: AnyKeyPath? = nil) =
  #externalMacro(module: "HarnessMacrosTCA2Plugin", type: "MarkerMacro")

/// Include a computed State property in the generated observation. Use with `@HarnessIgnore` on
/// stored fields to publish a projection (for example IDs instead of duplicated records).
@attached(peer)
public macro HarnessObserve() = #externalMacro(module: "HarnessMacrosTCA2Plugin", type: "MarkerMacro")

/// Generate a recursive schema. Properties must have explicit types conforming to
/// `HarnessInput`. Codable synthesis remains the application's responsibility.
@attached(member, names: named(harnessSchema))
@attached(extension, conformances: HarnessInput)
public macro HarnessSchema() = #externalMacro(module: "HarnessMacrosTCA2Plugin", type: "HarnessSchemaMacro")

/// Describe and bound a `String` field of a `@HarnessSchema` struct.
@attached(peer)
public macro HarnessField(_ description: String, minLength: Int? = nil, maxLength: Int? = nil) =
  #externalMacro(module: "HarnessMacrosTCA2Plugin", type: "MarkerMacro")

/// When an operation's receipt reports success.
public enum HarnessCompletion: Sendable {
  /// Running until every task the action started (`store.addTask`, triggered `onChange`, …)
  /// finishes. If the feature is dismounted first, the receipt reports `cancelled`.
  case effects
  /// Succeeded once the action is sent. Use for long-lived effects (timers, streams) and for
  /// actions whose effect dismisses their own feature.
  case dispatch
}

/// One selectable value for an `@HarnessOperation(choices:)` operation.
public struct HarnessChoice<Value> {
  public var value: Value
  public var id: String
  public var label: String
  public init(_ value: Value, id: String? = nil, label: String) {
    self.value = value
    self.id = id ?? String(describing: value)
    self.label = label
  }
}

/// Domain validation run after typed decoding and before dispatch.
public protocol HarnessValidating {
  func harnessValidate() throws
}

extension UUID: @retroactive HarnessInput {
  public static var harnessSchema: HarnessJSONSchema { .string(description: "UUID", minLength: 36, maxLength: 36) }
}
