import CasePaths
import ComposableArchitecture
import Foundation
import TCAHarness

/// A typed description of a feature; no store or model is owned here.
@MainActor
public struct FeatureDescriptor<State, Action> {
  public let name: String
  var observation: (State) -> HarnessValue
  var identity: (State) -> AnyHashable?
  var operations: [DescriptorOperation<State, Action>] = []
  var children: [(MountContext<State, Action>, RuntimeGraph) -> Void] = []
  var extraOffers: [(State, @escaping (Action) -> Void) -> [HarnessOffer]] = []

  public init(_ name: String, observation: @escaping (State) -> HarnessValue = { StateInspection.snapshot($0) },
    identity: @escaping (State) -> AnyHashable? = { ($0 as? any ObservableState).map { AnyHashable($0._$id) } }) {
    self.name = name; self.observation = observation; self.identity = identity
  }

  public func snapshot(_ state: State) -> HarnessValue { observation(state) }

  /// Explicit projections replace reflection when privacy or representation matters.
  public func observing(_ projection: @escaping (State) -> HarnessValue) -> Self {
    var copy = self; copy.observation = projection; return copy
  }

  public func operation(_ id: String, label: String? = nil, action: Action,
    available: @escaping (State) -> Bool = { _ in true },
    completion: ((State) -> HarnessOperationStatus)? = nil, cancel: Action? = nil) -> Self {
    adding(DescriptorOperation(id: id, label: label ?? id, schema: nil, available: available,
      build: { state, _ in action }, completion: completion, cancel: cancel))
  }

  public func operation<Input: HarnessInput>(_ id: String, label: String? = nil,
    arguments: Input.Type, action: @escaping (Input) -> Action,
    available: @escaping (State) -> Bool = { _ in true },
    validate: @escaping (State, Input) throws -> Void = { _, _ in },
    completion: ((State) -> HarnessOperationStatus)? = nil, cancel: Action? = nil) -> Self {
    let objectInput: Bool
    if case .object = Input.harnessSchema { objectInput = true } else { objectInput = false }
    let schema = objectInput ? Input.harnessSchema : .object(["value": Input.harnessSchema])
    return adding(DescriptorOperation(id: id, label: label ?? id, schema: HarnessArgumentSchema(schema),
      available: available, build: { state, data in
        let input = try objectInput ? JSONDecoder().decode(Input.self, from: data)
          : JSONDecoder().decode(HarnessValueInput<Input>.self, from: data).value
        try validate(state, input)
        return action(input)
      }, completion: completion, cancel: cancel))
  }

  public func valueOperation<Value: HarnessInput>(_ id: String, label: String? = nil,
    value: Value.Type, action: @escaping (Value) -> Action) -> Self {
    operation(id, label: label, arguments: HarnessValueInput<Value>.self, action: { action($0.value) })
  }

  private func adding(_ operation: DescriptorOperation<State, Action>) -> Self {
    var copy = self; copy.operations.append(operation); return copy
  }

  /// Ordinary and computed child scopes use the same checked, typed composition.
  public func child<ChildState, ChildAction>(_ name: String,
    state: @escaping (State) -> ChildState?, action: @escaping (ChildAction) -> Action,
    descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self {
    var copy = self
    copy.children.append { context, graph in
      let read = { context.read().flatMap(state) }
      descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name), parent: context.instance,
        read: read, send: { context.send(action($0)) }), graph: graph)
    }
    return copy
  }

  public func child<ChildState, ChildAction>(_ name: String, state: KeyPath<State, ChildState>,
    action: CaseKeyPath<Action, ChildAction>, descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self
  where Action: CasePathable {
    child(name, state: { $0[keyPath: state] }, action: { AnyCasePath(action).embed($0) }, descriptor: descriptor)
  }

  public func optional<ChildState, ChildAction>(_ name: String, state: KeyPath<State, ChildState?>,
    action: CaseKeyPath<Action, ChildAction>, descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self
  where Action: CasePathable {
    child(name, state: { $0[keyPath: state] }, action: { AnyCasePath(action).embed($0) }, descriptor: descriptor)
  }

  public func presentation<ChildState, ChildAction>(_ name: String, state: KeyPath<State, ChildState?>,
    action: CaseKeyPath<Action, PresentationAction<ChildAction>>, descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self
  where Action: CasePathable {
    child(name, state: { $0[keyPath: state] }, action: { AnyCasePath(action).embed(.presented($0)) }, descriptor: descriptor)
  }

  public func identified<ID: Hashable & Sendable, ChildState, ChildAction>(_ name: String,
    state: KeyPath<State, IdentifiedArray<ID, ChildState>>,
    action: CaseKeyPath<Action, IdentifiedAction<ID, ChildAction>>,
    descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self where Action: CasePathable {
    var copy = self
    copy.children.append { context, graph in
      guard let current = context.read() else { return }
      for id in current[keyPath: state].ids {
        descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name) + "/" + routeSegment(String(describing: id)), parent: context.instance,
          read: { context.read()?[keyPath: state][id: id] },
          send: { context.send(AnyCasePath(action).embed(.element(id: id, action: $0))) }), graph: graph)
      }
    }
    return copy
  }

  public func stack<ChildState, ChildAction>(_ name: String, state: KeyPath<State, StackState<ChildState>>,
    action: CaseKeyPath<Action, StackAction<ChildState, ChildAction>>,
    descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self where Action: CasePathable {
    var copy = self
    copy.children.append { context, graph in
      guard let current = context.read() else { return }
      for id in current[keyPath: state].ids {
        descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name) + "/" + routeSegment(String(describing: id)), parent: context.instance,
          read: { context.read()?[keyPath: state][id: id] },
          send: { context.send(AnyCasePath(action).embed(.element(id: id, action: $0))) }), graph: graph)
      }
    }
    return copy
  }

  public func bindings<Value: Codable & Equatable & Sendable>(_ field: WritableKeyPath<State, Value> & Sendable,
    name: String, numericRanges: [String: ClosedRange<Double>] = [:]) -> Self
  where State: ObservableState, Action: BindableAction, Action.State == State {
    var copy = self
    copy.extraOffers.append { current, send in
      CodableBindings.offers(value: current[keyPath: field], prefix: "binding/" + name, numericRanges: numericRanges) {
        send(Action.binding(.set(field, $0)))
      }
    }
    return copy
  }

  func mount(_ supplied: MountContext<State, Action>, graph: RuntimeGraph) {
    guard let current = supplied.read() else { return }
    let identity = identity(current)
    let instance = graph.lease(path: supplied.path, identity: identity, parent: supplied.parent)
    var context = supplied; context.instance = instance
    // Every captured read is checked against this mounted instance, including parents.
    let read = { [weak graph] () -> State? in
      guard let value = supplied.read(), self.identity(value) == identity,
        graph?.isCurrent(path: supplied.path, instance: instance) == true else { return nil }
      return value
    }
    let send: (Action) -> Void = { action in if read() != nil { supplied.send(action) } }
    var offers: [HarnessOffer] = []
    for operation in operations where operation.available(current) {
      let candidate = HarnessCandidate(id: context.path + "/" + routeSegment(operation.id) + "@" + instance,
        feature: context.path, label: operation.label, argumentSchema: operation.schema, instanceID: instance)
      offers.append(HarnessOffer(candidate: candidate) { data in
        guard let state = read(), operation.available(state) else { throw HarnessArgumentError("Feature or operation is no longer available") }
        let action = try operation.build(state, data)
        send(action)
        return HarnessOperation(cancel: operation.cancel.map { cancel in { send(cancel) } }, status: {
          guard let state = read() else { return .cancelled }
          return operation.completion?(state) ?? .succeeded
        })
      })
    }
    for provider in extraOffers { offers += provider(current, send).map { $0.scoped(feature: context.path, instanceID: instance) } }
    graph.add(HarnessFeatureInfo(path: context.path, name: name, instanceID: instance, operations: offers.map(\.candidate)), offers: offers)
    let childContext = MountContext(path: context.path, parent: context.parent, instance: instance, read: read, send: send)
    for child in children { child(childContext, graph) }
  }
}

@MainActor
struct DescriptorOperation<State, Action> {
  let id: String
  let label: String
  let schema: HarnessArgumentSchema?
  let available: (State) -> Bool
  let build: (State, Data) throws -> Action
  let completion: ((State) -> HarnessOperationStatus)?
  let cancel: Action?
}

@MainActor
struct MountContext<State, Action> {
  var path: String
  var parent: String?
  var instance = ""
  let read: () -> State?
  let send: (Action) -> Void
}

public struct HarnessValueInput<Value: HarnessInput>: HarnessInput {
  public let value: Value
  public static var harnessSchema: HarnessJSONSchema { .object(["value": Value.harnessSchema]) }
}

func routeSegment(_ value: String) -> String {
  // Escape all bytes outside the unreserved URL alphabet; slash and @ cannot alias routes.
  value.utf8.map { byte in
    ((65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45,46,95,126].contains(byte))
      ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
  }.joined()
}
