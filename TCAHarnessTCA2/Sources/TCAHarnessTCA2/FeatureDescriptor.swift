import ComposableArchitecture
import Foundation
import SwiftUI
import TCAHarness

/// A typed description of a TCA 2 feature; no store or model is owned here.
///
/// Descriptors mount against live stores. Child features are reached through the same store
/// APIs a view uses (`store.scope(\.child)`, `store.spawn(\.child)`), so operations act on the
/// child store directly: spawned children receive their own actions and state writes go
/// through the store like a SwiftUI binding.
@MainActor
public struct FeatureDescriptor<State, Action> {
  public let name: String
  var observation: (State) -> HarnessValue
  var operations: [DescriptorOperation<State, Action>] = []
  var children: [(MountContext<State, Action>, RuntimeGraph) -> Void] = []
  var configurationErrors: [String] = []
  var dismissLabel: String?

  public init(_ name: String, observation: @escaping (State) -> HarnessValue = { StateInspection.snapshot($0) }) {
    self.name = name
    self.observation = observation
  }

  public func snapshot(_ state: State) -> HarnessValue { observation(state) }

  /// Explicit projections replace generated or reflected observation.
  public func observing(_ projection: @escaping (State) -> HarnessValue) -> Self {
    var copy = self; copy.observation = projection; return copy
  }

  // MARK: Operations

  /// An operation with no arguments.
  public func operation(_ id: String, label: String? = nil, action: Action,
    available: @escaping (State) -> Bool = { _ in true },
    completion: HarnessCompletion = .effects, status: ((State) -> HarnessOperationStatus)? = nil) -> Self {
    adding(DescriptorOperation(id: id, available: available, completion: completion, status: status) { _ in
      [OfferSpec(route: id, label: label ?? id, schema: nil) { store, _ in store.send(action) }]
    })
  }

  /// An operation with typed arguments. Struct inputs use their fields directly; scalar, enum
  /// and array inputs are wrapped in `{ "value": … }`.
  public func operation<Input: HarnessInput>(_ id: String, label: String? = nil,
    arguments: Input.Type, action: @escaping (Input) -> Action,
    available: @escaping (State) -> Bool = { _ in true },
    validate: @escaping (State, Input) throws -> Void = { _, _ in },
    completion: HarnessCompletion = .effects, status: ((State) -> HarnessOperationStatus)? = nil) -> Self {
    let input = TypedInput<Input>()
    return adding(DescriptorOperation(id: id, available: available, completion: completion, status: status) { _ in
      [OfferSpec(route: id, label: label ?? id, schema: input.schema) { store, data in
        let value = try input.decode(data)
        try validate(store.state, value)
        return store.send(action(value))
      }]
    })
  }

  /// One candidate per current choice, e.g. "Complete: Buy groceries". The chosen value is
  /// re-checked against current state at dispatch.
  public func operation<Value>(_ id: String, label: String? = nil,
    choices: @escaping (State) -> [HarnessChoice<Value>], action: @escaping (Value) -> Action,
    available: @escaping (State) -> Bool = { _ in true },
    completion: HarnessCompletion = .effects, status: ((State) -> HarnessOperationStatus)? = nil) -> Self {
    adding(DescriptorOperation(id: id, available: available, completion: completion, status: status) { state in
      choices(state).map { choice in
        OfferSpec(route: id + "/" + routeSegment(choice.id), label: (label ?? id) + ": " + choice.label, schema: nil) { store, _ in
          guard let current = choices(store.state).first(where: { $0.id == choice.id }) else {
            throw HarnessArgumentError("Choice '\(choice.id)' is no longer available")
          }
          return store.send(action(current.value))
        }
      }
    })
  }

  /// One candidate per current choice, each also taking typed arguments.
  public func operation<Value, Input: HarnessInput>(_ id: String, label: String? = nil,
    choices: @escaping (State) -> [HarnessChoice<Value>], arguments: Input.Type,
    action: @escaping (Value, Input) -> Action,
    available: @escaping (State) -> Bool = { _ in true },
    completion: HarnessCompletion = .effects, status: ((State) -> HarnessOperationStatus)? = nil) -> Self {
    let input = TypedInput<Input>()
    return adding(DescriptorOperation(id: id, available: available, completion: completion, status: status) { state in
      choices(state).map { choice in
        OfferSpec(route: id + "/" + routeSegment(choice.id), label: (label ?? id) + ": " + choice.label, schema: input.schema) { store, data in
          let value = try input.decode(data)
          guard let current = choices(store.state).first(where: { $0.id == choice.id }) else {
            throw HarnessArgumentError("Choice '\(choice.id)' is no longer available")
          }
          return store.send(action(current.value, value))
        }
      }
    })
  }

  /// A typed setter that writes a state field through the store, exactly like a SwiftUI
  /// binding (`$store.name = value`). No action is sent; `onChange` observers still run.
  public func binding<Value: HarnessInput>(_ id: String, label: String? = nil,
    _ keyPath: WritableKeyPath<State, Value>,
    available: @escaping (State) -> Bool = { _ in true }) -> Self {
    let input = TypedInput<Value>()
    return adding(DescriptorOperation(id: id, available: available, completion: .dispatch, status: nil) { _ in
      [OfferSpec(route: id, label: label ?? "Set \(id)", schema: input.schema) { store, data in
        let value = try input.decode(data)
        Bindable(store)[dynamicMember: keyPath].wrappedValue = value
        return nil
      }]
    })
  }

  /// A `Bool` field offers the opposite value as one argument-free candidate (`<id>/true`).
  public func binding(_ id: String, label: String? = nil, _ keyPath: WritableKeyPath<State, Bool>,
    available: @escaping (State) -> Bool = { _ in true }) -> Self {
    finiteBinding(id, label: label, keyPath, values: [false, true], available: available)
  }

  /// A `String`-backed `CaseIterable` field offers one argument-free candidate per other case.
  public func binding<Value: HarnessInput & CaseIterable & RawRepresentable & Equatable>(_ id: String,
    label: String? = nil, _ keyPath: WritableKeyPath<State, Value>,
    available: @escaping (State) -> Bool = { _ in true }) -> Self where Value.RawValue == String {
    finiteBinding(id, label: label, keyPath, values: Array(Value.allCases), available: available)
  }

  private func finiteBinding<Value: Equatable>(_ id: String, label: String?, _ keyPath: WritableKeyPath<State, Value>,
    values: [Value], available: @escaping (State) -> Bool) -> Self {
    adding(DescriptorOperation(id: id, available: available, completion: .dispatch, status: nil) { state in
      values.filter { $0 != state[keyPath: keyPath] }.map { value in
        let text = routeID(value) ?? String(describing: value)
        return OfferSpec(route: id + "/" + routeSegment(text), label: (label ?? "Set \(id)") + ": " + text, schema: nil) { store, _ in
          Bindable(store)[dynamicMember: keyPath].wrappedValue = value
          return nil
        }
      }
    })
  }

  // MARK: Customizing operations by ID

  /// Additionally require `predicate` for the operation with `id`.
  public func available(_ id: String, _ predicate: @escaping (State) -> Bool) -> Self {
    updating(id) { operation in
      let existing = operation.available
      operation.available = { existing($0) && predicate($0) }
    }
  }

  /// Replace how the operation with `id` reports completion.
  public func completion(_ id: String, _ completion: HarnessCompletion,
    status: ((State) -> HarnessOperationStatus)? = nil) -> Self {
    updating(id) { $0.completion = completion; $0.status = status }
  }

  /// Remove the operation with `id`.
  public func removing(_ id: String) -> Self {
    var copy = updating(id) { _ in }
    copy.operations.removeAll { $0.id == id }
    return copy
  }

  private func updating(_ id: String, _ body: (inout DescriptorOperation<State, Action>) -> Void) -> Self {
    var copy = self
    guard let index = copy.operations.firstIndex(where: { $0.id == id }) else {
      copy.configurationErrors.append("\(name): no operation '\(id)' to customize")
      return copy
    }
    body(&copy.operations[index])
    return copy
  }

  private func adding(_ operation: DescriptorOperation<State, Action>) -> Self {
    var copy = self
    if copy.operations.contains(where: { $0.id == operation.id }) {
      copy.configurationErrors.append("\(name): duplicate operation '\(operation.id)'")
    }
    copy.operations.append(operation)
    return copy
  }

  /// Offer `dismiss` while this feature is presented, closing it as the back button or a swipe
  /// does. `@HarnessFeature(dismiss:)` applies this.
  public func dismissible(_ label: String) -> Self {
    var copy = self; copy.dismissLabel = label; return copy
  }

  // MARK: Children

  /// A single child reached through the parent store: `Scope`, `ifLet`, a `@Feature enum`
  /// case, or a spawned child. Return `nil` while the child is absent.
  public func child<ChildState, ChildAction>(_ name: String,
    descriptor: FeatureDescriptor<ChildState, ChildAction>,
    store derive: @escaping (Store<State, Action>) -> Store<ChildState, ChildAction>?) -> Self {
    var copy = self
    copy.children.append { context, graph in
      descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name), parent: context.instance,
        resolve: { context.resolve().flatMap(derive) }), graph: graph)
    }
    return copy
  }

  /// A collection of identified children: `forEach`, stack paths, or spawned arrays. Elements
  /// with readable IDs (strings, integers, UUIDs) mount at `name/<id>`; others, such as stack
  /// path elements, mount at `name/<index>`. Either way a route resolves to the element by ID.
  public func children<ChildState: Identifiable, ChildAction>(_ name: String,
    descriptor: FeatureDescriptor<ChildState, ChildAction>,
    stores derive: @escaping (Store<State, Action>) -> [Store<ChildState, ChildAction>]) -> Self {
    children(name, descriptor: descriptor, stores: derive,
      route: { child, index in routeID(child.state.id) ?? String(index) },
      matches: { child in
        let id = AnyHashable(child.state.id)
        return { AnyHashable($0.state.id) == id }
      })
  }

  /// A collection of spawned children whose state isn't `Identifiable` (`[Spawn<Child>]`).
  /// Elements mount at `name/<index>` and resolve to the same spawned store.
  public func children<ChildState, ChildAction>(_ name: String,
    descriptor: FeatureDescriptor<ChildState, ChildAction>,
    stores derive: @escaping (Store<State, Action>) -> [Store<ChildState, ChildAction>]) -> Self {
    children(name, descriptor: descriptor, stores: derive,
      route: { _, index in String(index) },
      matches: { child in { $0 == child } })
  }

  private func children<ChildState, ChildAction>(_ name: String,
    descriptor: FeatureDescriptor<ChildState, ChildAction>,
    stores derive: @escaping (Store<State, Action>) -> [Store<ChildState, ChildAction>],
    route: @escaping (Store<ChildState, ChildAction>, Int) -> String,
    matches: @escaping (Store<ChildState, ChildAction>) -> (Store<ChildState, ChildAction>) -> Bool) -> Self {
    var copy = self
    copy.children.append { context, graph in
      for error in descriptor.configurationErrors { graph.diagnose(error) }
      guard let parent = context.resolve() else { return }
      for (index, child) in derive(parent).enumerated() {
        let isElement = matches(child)
        descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name) + "/" + routeSegment(route(child, index)),
          parent: context.instance,
          resolve: { context.resolve().flatMap { derive($0).first(where: isElement) } }), graph: graph)
      }
    }
    return copy
  }

  // MARK: Mounting

  func mount(_ supplied: MountContext<State, Action>, graph: RuntimeGraph) {
    for error in configurationErrors { graph.diagnose(error) }
    guard let current = supplied.resolve() else { return }
    let instance = graph.lease(path: supplied.path, identity: AnyHashable(current), parent: supplied.parent)
    // Every later resolution is checked against this mounted store and lease, including parents.
    let resolve = { [weak graph] () -> Store<State, Action>? in
      guard let store = supplied.resolve(), store == current,
        graph?.isCurrent(path: supplied.path, instance: instance) == true else { return nil }
      return store
    }
    let state = current.state
    var offers: [HarnessOffer] = []
    for operation in operations where operation.available(state) {
      for spec in operation.offers(state) {
        let candidate = HarnessCandidate(id: supplied.path + "/" + spec.route + "@" + instance,
          feature: supplied.path, label: spec.label, argumentSchema: spec.schema, instanceID: instance)
        offers.append(HarnessOffer(candidate: candidate) { data in
          guard let store = resolve(), operation.available(store.state) else {
            throw HarnessArgumentError("Feature or operation is no longer available")
          }
          let task = try spec.perform(store, data)
          return EffectReceipt(task: operation.completion == .effects ? task : nil,
            status: operation.status, resolve: resolve).operation
        })
      }
    }
    // A presented feature can be closed the way a person would, with the back button or a swipe.
    if let dismissLabel, current.isPresented {
      let candidate = HarnessCandidate(id: supplied.path + "/dismiss@" + instance, feature: supplied.path,
        label: dismissLabel, instanceID: instance)
      offers.append(HarnessOffer(candidate: candidate) { _ in
        guard let store = resolve(), store.isPresented else {
          throw HarnessArgumentError("Feature or operation is no longer available")
        }
        store.dismiss()
        return .completed
      })
    }
    graph.add(HarnessFeatureInfo(path: supplied.path, name: name, instanceID: instance,
      operations: offers.map(\.candidate)), offers: offers)
    let context = MountContext(path: supplied.path, parent: supplied.parent, instance: instance, resolve: resolve)
    for child in children { child(context, graph) }
  }
}

@MainActor
struct DescriptorOperation<State, Action> {
  let id: String
  var available: (State) -> Bool
  var completion: HarnessCompletion
  var status: ((State) -> HarnessOperationStatus)?
  let offers: (State) -> [OfferSpec<State, Action>]

  init(id: String, available: @escaping (State) -> Bool, completion: HarnessCompletion,
    status: ((State) -> HarnessOperationStatus)?, offers: @escaping (State) -> [OfferSpec<State, Action>]) {
    self.id = id; self.available = available; self.completion = completion; self.status = status; self.offers = offers
  }
}

@MainActor
struct OfferSpec<State, Action> {
  let route: String
  let label: String
  let schema: HarnessArgumentSchema?
  /// Returns the task tied to the work the dispatch started, as `Store.send` does.
  let perform: (Store<State, Action>, Data) throws -> Task<Void, Never>?
}

@MainActor
struct MountContext<State, Action> {
  var path: String
  var parent: String?
  var instance = ""
  let resolve: () -> Store<State, Action>?
}

/// Tracks the task returned by `Store.send` so a receipt can wait for the action's effects.
@MainActor
final class EffectReceipt<State, Action> {
  private var outcome: HarnessOperationStatus?
  private let task: Task<Void, Never>?
  private let status: ((State) -> HarnessOperationStatus)?
  private let resolve: () -> Store<State, Action>?

  init(task: Task<Void, Never>?, status: ((State) -> HarnessOperationStatus)?, resolve: @escaping () -> Store<State, Action>?) {
    self.task = task; self.status = status; self.resolve = resolve
    guard let task else { return }
    Task { [weak self] in
      await task.value
      guard let self, self.outcome == nil else { return }
      // Dismounting a feature cancels its tasks, so finishing without a live feature is a cancellation.
      self.outcome = self.resolve() == nil ? .cancelled : .succeeded
    }
  }

  var operation: HarnessOperation {
    HarnessOperation(cancel: task.map { task in { [weak self] in
      task.cancel()
      self?.outcome = .cancelled
    } }) { [self] in
      if outcome == .cancelled { return .cancelled }
      if task != nil, outcome == nil {
        return resolve() == nil ? .cancelled : .running
      }
      guard let status else { return outcome ?? .succeeded }
      guard let store = resolve() else { return .cancelled }
      return status(store.state)
    }
  }
}

/// Struct-shaped inputs use their fields directly; others are wrapped in `{ "value": … }`.
struct TypedInput<Input: HarnessInput> {
  let objectInput: Bool
  let schema: HarnessArgumentSchema
  init() {
    if case .object = Input.harnessSchema { objectInput = true } else { objectInput = false }
    schema = HarnessArgumentSchema(objectInput ? Input.harnessSchema : .object(["value": Input.harnessSchema]))
  }
  func decode(_ data: Data) throws -> Input {
    let value = try objectInput ? JSONDecoder().decode(Input.self, from: data)
      : JSONDecoder().decode(HarnessValueInput<Input>.self, from: data).value
    try (value as? HarnessValidating)?.harnessValidate()
    return value
  }
}

public struct HarnessValueInput<Value: HarnessInput>: HarnessInput {
  public let value: Value
  public static var harnessSchema: HarnessJSONSchema { .object(["value": Value.harnessSchema]) }
}

/// A readable, stable route component for an element ID, or nil to fall back to its index.
func routeID(_ id: Any) -> String? {
  switch id {
  case let id as UUID: return id.uuidString
  case let id as any LosslessStringConvertible: return id.description
  case let id as any RawRepresentable: return routeID(id.rawValue)
  default: return nil
  }
}

func routeSegment(_ value: String) -> String {
  // Escape all bytes outside the unreserved URL alphabet; slash and @ cannot alias routes.
  value.utf8.map { byte in
    ((65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte))
      ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
  }.joined()
}
