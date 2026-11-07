import ComposableArchitecture
import Foundation
import TCAHarness

// Plain `@Observable` models, the vanilla SwiftUI way, use the same descriptors, sessions and CLI as
// TCA features. A model descriptor is a `FeatureDescriptor` whose state is the model object and whose
// actions are calls to its methods. Host one of three ways:
//
// 1. As the app's root: `ModelHarness(model, descriptor:)`.
// 2. Inside a TCA app, as a child of a feature descriptor: `.model("settings", { $0.settings }, descriptor:)`.
// 3. Wrapped in TCA with `Hosted<Model>`, so its operations become actions in the store: they show up in
//    the devtools timeline, run as effects, and can be tested with `TestStore`.

/// A model descriptor: state is the model object, actions are calls to its methods.
public typealias ModelDescriptor<Model: AnyObject> = FeatureDescriptor<Model, ModelAction<Model>>

/// One call into a model method, made by the harness. It carries its own progress so a receipt stays
/// `running` until async work finishes.
@MainActor
public final class ModelAction<Model: AnyObject> {
  /// The operation id, e.g. `refresh`.
  public let id: String
  let body: @MainActor (Model) async throws -> Void
  private(set) var status: HarnessOperationStatus = .running
  private var task: Task<Void, Never>?

  /// Nonisolated so a reducer can build one (see `Hosted.Action.call`).
  nonisolated init(id: String, body: @escaping @MainActor (Model) async throws -> Void) {
    self.id = id; self.body = body
  }

  /// Runs the call on `model` in a new task. An error that escapes the method is recorded as an issue,
  /// because the user got no feedback from it; the receipt reports `failed`.
  func start(on model: Model, issues: HarnessIssueLog = .shared) {
    guard task == nil else { return }
    task = Task { @MainActor in await self.run(on: model, issues: issues) }
  }

  /// Runs the call to completion on `model`, updating `status`.
  func run(on model: Model, issues: HarnessIssueLog = .shared) async {
    do {
      try await body(model)
      status = .succeeded
    } catch is CancellationError {
      status = .cancelled
    } catch {
      status = .failed
      issues.record(kind: "issue", message: "\(String(describing: Model.self)).\(id) threw: \(error)")
    }
  }

  func cancel() { task?.cancel() }
}

extension ModelAction: CustomStringConvertible, HarnessActionSegment {
  nonisolated public var description: String { MainActor.assumeIsolated { id } }
  nonisolated var harnessActionSegment: String { description }
}

/// The operation id of a finished model call, named in timeline paths.
public struct ModelCallID: Hashable, Sendable, HarnessActionSegment {
  public let id: String
  var harnessActionSegment: String { id }
}

extension FeatureDescriptor where State: AnyObject, Action == ModelAction<State> {
  /// A descriptor for an `@Observable` model. By default the observation reflects the model's stored
  /// properties (and nested model objects); pass `observation` to publish an explicit projection.
  public static func model(_ name: String, observation: ((State) -> HarnessValue)? = nil) -> Self {
    FeatureDescriptor(name,
      observation: observation ?? { StateInspection.snapshot($0, reflectingObjects: true) },
      identity: { AnyHashable(ObjectIdentifier($0)) })
  }

  /// An operation that calls a model method. The receipt is `running` until `perform` returns.
  public func operation(_ id: String, label: String? = nil,
    available: @escaping (State) -> Bool = { _ in true },
    perform: @escaping @MainActor (State) async throws -> Void) -> Self {
    var operation = DescriptorOperation<State, Action>(id: id, label: label ?? id, schema: nil, available: available,
      build: { _, _ in ModelAction(id: id, body: perform) }, completion: nil, cancel: nil)
    operation.track = { action in { action.status } }
    return adding(operation)
  }

  /// An operation that calls a model method with typed arguments, validated against `Input`'s schema.
  public func operation<Input: HarnessInput>(_ id: String, label: String? = nil, arguments: Input.Type,
    available: @escaping (State) -> Bool = { _ in true },
    validate: @escaping (State, Input) throws -> Void = { _, _ in },
    perform: @escaping @MainActor (State, Input) async throws -> Void) -> Self {
    var copy = operation(id, label: label, arguments: arguments,
      action: { input in ModelAction(id: id) { try await perform($0, input) } },
      available: available, validate: validate)
    copy.operations[copy.operations.count - 1].track = { action in { action.status } }
    return copy
  }
}

extension FeatureDescriptor {
  /// Mounts an `@Observable` model as a child feature at `<path>/<name>`, for vanilla SwiftUI screens
  /// inside a TCA app. `model` finds the object from this feature's state, or returns nil when the
  /// screen isn't showing. Its operations call the model directly, not through the store.
  ///
  /// The model's projection is also added to this feature's observation under `name`, so journey
  /// checks and `tca ls` see it with the rest of the state.
  public func model<Model: AnyObject>(_ name: String, _ model: @escaping (State) -> Model?,
    descriptor: ModelDescriptor<Model>, issues: HarnessIssueLog = .shared) -> Self {
    var copy = self
    copy.children.append { context, graph in
      let read = { context.read().flatMap(model) }
      descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name), parent: context.instance,
        read: read, send: { action in if let object = read() { action.start(on: object, issues: issues) } }), graph: graph)
    }
    let parentObservation = copy.observation
    copy.observation = { state in
      guard case var .object(fields) = parentObservation(state) else { return parentObservation(state) }
      fields[name] = model(state).map(descriptor.observation) ?? .null
      return .object(fields)
    }
    return copy.addingChildInvariants(descriptor) { parent in model(parent).map { [(routeSegment(name), $0)] } ?? [] }
  }
}

/// Attaches the harness to a vanilla SwiftUI app whose root is an `@Observable` model.
///
/// ```swift
/// let harness = ModelHarness(appModel, descriptor: AppModel.harnessDescriptor)
/// try harness.startIfEnabled()
/// ```
///
/// There is no reducer, so the devtools timeline isn't recorded; host the model in TCA with `Hosted`
/// when you want it.
@MainActor
public final class ModelHarness<Model: AnyObject> {
  public let runtime: HarnessRuntime<Model, ModelAction<Model>>
  public let server: HarnessServer
  private let issueReporter: HarnessIssueReporter?

  public init(_ model: Model, descriptor: ModelDescriptor<Model>,
    verify: @escaping (Model, String) -> Bool? = { _, _ in nil }, issues: HarnessIssueLog = .shared) {
    let runtime = HarnessRuntime(descriptor: descriptor, read: { model },
      send: { $0.start(on: model, issues: issues) }, verify: verify, timeline: nil, issues: issues)
    self.runtime = runtime
    server = HarnessServer { await runtime.session.handleJSON($0) }
    issueReporter = HarnessServer.isAvailable ? HarnessIssueReporter.install(log: issues) : nil
  }

  deinit { issueReporter?.uninstall() }

  /// Starts the loopback listener on `port`. Throws in builds compiled without `DEBUG`.
  public func start(port: UInt16 = 8765) throws { try server.start(port: port) }

  /// Stops the listener.
  public func stop() { server.stop() }

  /// Serves the model with no UI until stopped or cancelled. See `StoreHarness.runHeadless(port:)`.
  public func runHeadless(port: UInt16 = 8765) async throws {
    try await server.run(port: port) {
      FileHandle.standardError.write(Data("TCA harness listening on 127.0.0.1:\(port)\n".utf8))
    }
  }

  /// Starts the listener when the app was launched with `TCA_HARNESS=1`, on `TCA_HARNESS_PORT` or
  /// `defaultPort`. Returns false, without reading the environment, in builds without `DEBUG`.
  @discardableResult
  public func startIfEnabled(environment: [String: String] = ProcessInfo.processInfo.environment,
    defaultPort: UInt16 = 8765) throws -> Bool {
    guard let port = try harnessPort(environment: environment, defaultPort: defaultPort) else { return false }
    try start(port: port)
    return true
  }
}

/// The port to listen on for `TCA_HARNESS=1` launches, or nil when the harness isn't enabled.
func harnessPort(environment: [String: String], defaultPort: UInt16) throws -> UInt16? {
  guard HarnessServer.isAvailable, environment["TCA_HARNESS"] == "1" else { return nil }
  if let text = environment["TCA_HARNESS_PORT"] {
    guard let value = UInt16(text), value != 0 else {
      throw HarnessArgumentError("TCA_HARNESS_PORT must be an integer from 1 to 65535")
    }
    return value
  }
  guard defaultPort != 0 else { throw HarnessArgumentError("Harness port must be from 1 to 65535") }
  return defaultPort
}

/// Hosts an `@Observable` model inside a TCA store. Each harness operation becomes a `perform` action
/// that runs the model method as an effect, so vanilla screens get the timeline, effect lifecycles,
/// cancellation on dismissal and `TestStore` like any other feature.
///
/// ```swift
/// // Parent state:   @Presents var settings: Hosted<SettingsModel>.State?
/// // Parent reducer: .ifLet(\.$settings, action: \.settings) { Hosted<SettingsModel>() }
/// // Descriptor:     .presentation("settings", state: \.settings, action: \.settings,
/// //                   descriptor: Hosted.descriptor(SettingsModel.harnessDescriptor))
/// // View:           SettingsView(model: store.model)
/// ```
public struct Hosted<Model: AnyObject & Sendable>: Reducer {
  /// `ObservableState`, so a view reads `store.model` from a scoped store.
  @ObservableState
  public struct State: Equatable, HarnessSnapshotProviding {
    /// The hosted model. Views observe it directly.
    public let model: Model
    /// Calls in flight, by operation id.
    public var running: [String: Int] = [:]

    /// The model as of the last `Hosted` action (DEBUG builds only). The model is a reference, so
    /// the devtools timeline, which snapshots captured states later, would otherwise show every entry
    /// with the model's current values and no changes.
    @ObservationStateIgnored var recorded: HarnessValue?

    public init(_ model: Model) {
      self.model = model
      record()
    }

    mutating func record() {
      #if DEBUG
      recorded = StateInspection.snapshot(model, reflectingObjects: true)
      #endif
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.running == rhs.running }

    /// A parent's reflected observation (e.g. `@HarnessFeature`'s) shows the model's stored
    /// properties, the same view as the model descriptor's default.
    var harnessSnapshot: HarnessValue {
      if HarnessSnapshotContext.recorded, let recorded { return recorded }
      return StateInspection.snapshot(model, reflectingObjects: true)
    }
  }

  @CasePathable
  public enum Action {
    /// Run one model method, as an effect.
    case perform(ModelAction<Model>)
    /// The method returned (or threw; the error is recorded as an issue).
    case finished(ModelCallID)
    /// Dismiss the hosted screen through `@Dependency(\.dismiss)`, like a TCA child's Close button.
    /// Give it an operation with `Hosted.descriptor(...).operation("close", label: "Close", action: .dismiss)`.
    case dismiss

    /// A call the parent reducer starts, e.g. the initial load when it presents the screen:
    /// `return .send(.stats(.presented(.call("load") { await $0.load() })))`. It runs, and shows in
    /// the timeline, exactly like a harness operation with the same id.
    public static func call(_ id: String, _ body: @escaping @MainActor (Model) async throws -> Void) -> Self {
      .perform(ModelAction(id: id, body: body))
    }
  }

  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .perform(call):
        let id = MainActor.assumeIsolated { call.id }
        state.running[id, default: 0] += 1
        state.record()
        let model = UncheckedSendable(state.model)
        return .run { send in
          await call.run(on: model.value)
          await send(.finished(ModelCallID(id: id)))
        }
      case let .finished(call):
        let id = call.id
        state.running[id, default: 1] -= 1
        if state.running[id] == 0 { state.running[id] = nil }
        state.record()
        return .none
      case .dismiss:
        return .run { [dismiss] _ in await dismiss() }
      }
    }
  }

  /// The TCA descriptor for a hosted model, built from the model's own descriptor: same name,
  /// observation, operations, invariants and nested models. Operations dispatch `perform` actions.
  @MainActor
  public static func descriptor(_ model: ModelDescriptor<Model>) -> FeatureDescriptor<State, Action> {
    var hosted = FeatureDescriptor<State, Action>(model.name,
      observation: { model.observation($0.model) }, identity: { AnyHashable(ObjectIdentifier($0.model)) })
    for operation in model.operations {
      hosted = hosted.adding(DescriptorOperation(id: operation.id, label: operation.label, schema: operation.schema,
        available: { operation.available($0.model) },
        build: { state, data in .perform(try operation.build(state.model, data)) },
        completion: { $0.running[operation.id, default: 0] > 0 ? .running : .succeeded }, cancel: nil))
    }
    for invariant in model.invariants {
      hosted = hosted.invariant(invariant.name) { invariant.check($0.model) }
    }
    for child in model.childInvariants {
      hosted.childInvariants.append { state, path, results in child(state.model, path, &results) }
    }
    for child in model.children {
      // Nested models keep calling their own methods directly.
      hosted.children.append { context, graph in
        child(MountContext(path: context.path, parent: context.parent, instance: context.instance,
          read: { context.read()?.model }, send: { action in if let object = context.read()?.model { action.start(on: object) } }), graph)
      }
    }
    return hosted
  }
}
