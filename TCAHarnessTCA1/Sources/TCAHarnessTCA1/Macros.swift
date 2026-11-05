import TCAHarness

/// Generates a harness descriptor for a `@Reducer` from its locally declared `State` and `Action`.
///
/// No-payload `…ButtonTapped` actions are exposed as operations by convention; other actions opt in
/// with `@HarnessOperation`. Child features declared through `Scope`, `ifLet`, `forEach` and stack
/// state become nested features, and can be extended explicitly on the generated descriptor.
/// The generated `HarnessFeatureProvider` conformance enables `store.harness(Feature.self)`.
///
/// ```swift
/// @HarnessFeature
/// @Reducer
/// struct Counter { ... }
/// ```
@attached(member, names: named(harnessDescriptor))
@attached(extension, conformances: HarnessFeatureProvider)
public macro HarnessFeature() = #externalMacro(module: "HarnessMacrosPlugin", type: "HarnessFeatureMacro")

/// Opts an action case into discovery as an operation.
///
/// - Parameter label: A human-readable label. Defaults to the case name.
@attached(peer)
public macro HarnessOperation(_ label: String? = nil) = #externalMacro(module: "HarnessMacrosPlugin", type: "MarkerMacro")

/// Exclude a case or stored field from generated metadata.
@attached(peer)
public macro HarnessIgnore() = #externalMacro(module: "HarnessMacrosPlugin", type: "MarkerMacro")

/// Generates a recursive argument schema for a struct used as an action payload.
///
/// Properties must have explicit types conforming to `HarnessInput`. `Codable` synthesis remains
/// the application's responsibility.
@attached(member, names: named(harnessSchema))
@attached(extension, conformances: HarnessInput)
public macro HarnessSchema() = #externalMacro(module: "HarnessMacrosPlugin", type: "HarnessSchemaMacro")
