import CasePaths
import ComposableArchitecture
import Foundation
import TCAHarnessCore

/// A typed description of a feature; no store or model is owned here.
@MainActor
public struct FeatureDescriptor<State, Action> {
  public let name: String
  var observation: (State) -> HarnessValue
  var identity: (State) -> AnyHashable?
  var operations: [DescriptorOperation<State, Action>] = []
  var children: [(MountContext<State, Action>, RuntimeGraph) -> Void] = []
  var extraOffers: [(State, @escaping (Action) -> Void) -> [HarnessOffer]] = []
  var invariants: [(name: String, check: (State) -> Bool)] = []
  /// Evaluates mounted children's invariants; only children that declare some are kept.
  var childInvariants: [(State, String, inout [(name: String, holds: Bool)]) -> Void] = []
  var hasInvariants: Bool { !invariants.isEmpty || !childInvariants.isEmpty }
  /// Action cases no operation sends, with why; `@HarnessFeature` fills this, `unexposed(_:reason:)` adds to it.
  var unexposedActions: [HarnessUnexposedAction] = []
  /// Action case names that operations and child scopes do send; they are left out of `unexposedActions`.
  var coveredActions: Set<String> = []
  /// What `inspect` reports as unexposed: the declared entries no operation or child turned out to cover.
  var unexposed: [HarnessUnexposedAction] { unexposedActions.filter { !coveredActions.contains($0.action) } }
  /// The catalog of each composed child, given this feature's path.
  var childCatalogs: [(String) -> [HarnessCatalogFeature]] = []
  var declaredOperations: [HarnessDeclaredOperation] {
    operations.map { HarnessDeclaredOperation(id: routeSegment($0.id), label: $0.label) }
  }

  /// This feature and every child it can mount, whether or not they are mounted for the current state.
  /// Collection elements appear once, with `{id}` as their segment (`root/books/{id}`).
  public func catalog(path: String = "root") -> [HarnessCatalogFeature] {
    [HarnessCatalogFeature(path: path, name: name, declaredOperations: declaredOperations, unexposed: unexposed)]
      + childCatalogs.flatMap { $0(path) }
  }

  func addingChildCatalog<ChildState, ChildAction>(_ segment: String, _ descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self {
    var copy = self; copy.childCatalogs.append { descriptor.catalog(path: $0 + "/" + segment) }; return copy
  }

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
      build: { state, _ in action }, completion: completion, cancel: cancel, actionCase: actionCaseName(action)))
  }

  /// An operation whose action is built from the state when it is dispatched, for actions that carry
  /// a value the user is looking at, such as `.selectRide(ride)` for a row that isn't an identified child.
  public func operation(_ id: String, label: String? = nil,
    available: @escaping (State) -> Bool = { _ in true },
    completion: ((State) -> HarnessOperationStatus)? = nil, cancel: Action? = nil,
    action: @escaping (State) -> Action) -> Self {
    adding(DescriptorOperation(id: id, label: label ?? id, schema: nil, available: available,
      build: { state, _ in action(state) }, completion: completion, cancel: cancel))
  }

  public func operation<Input: HarnessInput>(_ id: String, label: String? = nil,
    arguments: Input.Type, action: @escaping (Input) -> Action,
    available: @escaping (State) -> Bool = { _ in true },
    validate: @escaping (State, Input) throws -> Void = { _, _ in },
    completion: ((State) -> HarnessOperationStatus)? = nil, cancel: Action? = nil) -> Self {
    let objectInput: Bool
    if case .object = Input.harnessSchema { objectInput = true } else { objectInput = false }
    let schema = objectInput ? Input.harnessSchema : .object(["value": Input.harnessSchema])
    let decode = { (data: Data) throws -> Input in
      try objectInput ? JSONDecoder().decode(Input.self, from: data)
        : JSONDecoder().decode(HarnessValueInput<Input>.self, from: data).value
    }
    // Which action case this sends, from a sample input, so `inspect` doesn't list it as unexposed.
    let actionCase = sampleArguments(schema).flatMap { try? decode($0) }.flatMap { actionCaseName(action($0)) }
    return adding(DescriptorOperation(id: id, label: label ?? id, schema: HarnessArgumentSchema(schema),
      available: available, build: { state, data in
        let input = try decode(data)
        try validate(state, input)
        return action(input)
      }, completion: completion, cancel: cancel, actionCase: actionCase))
  }

  public func valueOperation<Value: HarnessInput>(_ id: String, label: String? = nil,
    value: Value.Type, action: @escaping (Value) -> Action) -> Self {
    operation(id, label: label, arguments: HarnessValueInput<Value>.self, action: { action($0.value) })
  }

  /// Declares something that must always be true of this feature's state, such as
  /// "no duplicate books". Invariants are checked after every reduced action when the root reducer
  /// has `.harnessTimeline()`, and on every observation and dispatch through the session. When one
  /// changes from holding to violated, an `invariant` issue is recorded whose message is the
  /// feature path and the name, e.g. `root/shelf: no duplicate books`. Composed children keep their
  /// invariants under their own path; identified and stack elements include the element id.
  ///
  /// `check` runs often, on the main actor; keep it cheap and free of side effects.
  public func invariant(_ name: String, _ check: @escaping (State) -> Bool) -> Self {
    var copy = self; copy.invariants.append((name, check)); return copy
  }

  /// Every invariant of this feature and its mounted children for `state`, named `<path>: <name>`.
  public func evaluateInvariants(_ state: State, path: String = "root") -> [(name: String, holds: Bool)] {
    var results: [(name: String, holds: Bool)] = []
    collectInvariants(state, path: path, into: &results)
    return results
  }

  func collectInvariants(_ state: State, path: String, into results: inout [(name: String, holds: Bool)]) {
    for invariant in invariants { results.append((path + ": " + invariant.name, invariant.check(state))) }
    for child in childInvariants { child(state, path, &results) }
  }

  func addingChildInvariants<ChildState, ChildAction>(_ descriptor: FeatureDescriptor<ChildState, ChildAction>,
    _ children: @escaping (State) -> [(segment: String, state: ChildState)]) -> Self {
    guard descriptor.hasInvariants else { return self }
    var copy = self
    copy.childInvariants.append { state, path, results in
      for child in children(state) { descriptor.collectInvariants(child.state, path: path + "/" + child.segment, into: &results) }
    }
    return copy
  }

  func adding(_ operation: DescriptorOperation<State, Action>) -> Self {
    var copy = self; copy.operations.append(operation)
    copy.coveredActions.insert(operation.id)
    if let name = operation.actionCase { copy.coveredActions.insert(name) }
    return copy
  }

  /// Records an action case that no operation sends, for `tca exposure`: `.unexposed("routeTapped",
  /// reason: "opens Apple Maps")`. `@HarnessFeature` adds every case it didn't turn into an operation.
  /// An entry is dropped from `inspect` once an operation sends that case (or uses it as its ID) or
  /// a child scope is mounted under that name.
  public func unexposed(_ action: String, reason: String) -> Self {
    var copy = self; copy.unexposedActions.append(HarnessUnexposedAction(action: action, reason: reason)); return copy
  }

  /// Marks action cases as sent by this descriptor when no operation or child can be matched to them
  /// by name: an identified collection mounted under another name (`.identified("books", action:
  /// \.bookRows, ...)`), or an operation that builds its action from state under another ID.
  public func covering(_ actions: String?...) -> Self {
    var copy = self; copy.coveredActions.formUnion(actions.compactMap { $0 }); return copy
  }

  /// Ordinary and computed child scopes use the same checked, typed composition.
  public func child<ChildState, ChildAction>(_ name: String,
    state: @escaping (State) -> ChildState?, action: @escaping (ChildAction) -> Action,
    descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self {
    var copy = addingChildCatalog(routeSegment(name), descriptor)
    copy.coveredActions.insert(name)
    copy.children.append { context, graph in
      let read = { context.read().flatMap(state) }
      descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name), parent: context.instance,
        read: read, send: { context.send(action($0)) }), graph: graph)
    }
    return copy.addingChildInvariants(descriptor) { parent in
      state(parent).map { [(routeSegment(name), $0)] } ?? []
    }
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
      .covering(actionCaseName(AnyCasePath(action).embed(.dismiss)))
  }

  public func identified<ID: Hashable & Sendable, ChildState, ChildAction>(_ name: String,
    state: KeyPath<State, IdentifiedArray<ID, ChildState>>,
    action: CaseKeyPath<Action, IdentifiedAction<ID, ChildAction>>,
    descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self where Action: CasePathable {
    var copy = addingChildCatalog(routeSegment(name) + "/{id}", descriptor)
    copy.coveredActions.insert(name)
    copy.children.append { context, graph in
      guard let current = context.read() else { return }
      for id in current[keyPath: state].ids {
        descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name) + "/" + routeSegment(String(describing: id)), parent: context.instance,
          read: { context.read()?[keyPath: state][id: id] },
          send: { context.send(AnyCasePath(action).embed(.element(id: id, action: $0))) }), graph: graph)
      }
    }
    return copy.addingChildInvariants(descriptor) { parent in
      let elements = parent[keyPath: state]
      return elements.ids.compactMap { id in
        elements[id: id].map { (routeSegment(name) + "/" + routeSegment(String(describing: id)), $0) }
      }
    }
  }

  public func stack<ChildState, ChildAction>(_ name: String, state: KeyPath<State, StackState<ChildState>>,
    action: CaseKeyPath<Action, StackAction<ChildState, ChildAction>>,
    descriptor: FeatureDescriptor<ChildState, ChildAction>) -> Self where Action: CasePathable {
    var copy = covering(actionCaseName(AnyCasePath(action).embed(.popFrom(id: 0))))
      .addingChildCatalog(routeSegment(name) + "/{id}", descriptor)
    copy.coveredActions.insert(name)
    copy.children.append { context, graph in
      guard let current = context.read() else { return }
      for id in current[keyPath: state].ids {
        descriptor.mount(MountContext(path: context.path + "/" + routeSegment(name) + "/" + routeSegment(String(describing: id)), parent: context.instance,
          read: { context.read()?[keyPath: state][id: id] },
          send: { context.send(AnyCasePath(action).embed(.element(id: id, action: $0))) }), graph: graph)
      }
    }
    return copy.addingChildInvariants(descriptor) { parent in
      let elements = parent[keyPath: state]
      return elements.ids.compactMap { id in
        elements[id: id].map { (routeSegment(name) + "/" + routeSegment(String(describing: id)), $0) }
      }
    }
  }

  public func bindings<Value: Codable & Equatable & Sendable>(_ field: WritableKeyPath<State, Value> & Sendable,
    name: String, numericRanges: [String: ClosedRange<Double>] = [:]) -> Self
  where State: ObservableState, Action: BindableAction, Action.State == State {
    var copy = self
    copy.coveredActions.insert("binding")
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
        // Actions that carry their own progress (model operations) report it directly.
        let tracked = operation.track?(action)
        return HarnessOperation(cancel: operation.cancel.map { cancel in { send(cancel) } }, status: {
          if let tracked { return tracked() }
          guard let state = read() else { return .cancelled }
          return operation.completion?(state) ?? .succeeded
        })
      })
    }
    for provider in extraOffers { offers += provider(current, send).map { $0.scoped(feature: context.path, instanceID: instance) } }
    graph.add(HarnessFeatureInfo(path: context.path, name: name, instanceID: instance, operations: offers.map(\.candidate),
      declaredOperations: declaredOperations, unexposed: unexposed), offers: offers)
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
  /// The action case this operation sends, when it can be told without state.
  var actionCase: String? = nil
  /// Status for one dispatched action, when the action itself knows (see `ModelAction`).
  var track: ((Action) -> () -> HarnessOperationStatus)? = nil
}

/// `rename` for `.rename(...)`, `saveButtonTapped` for `.saveButtonTapped`; nil for non-enum actions.
func actionCaseName(_ action: Any) -> String? {
  let mirror = Mirror(reflecting: action)
  guard mirror.displayStyle == .enum else { return nil }
  if let label = mirror.children.first?.label { return label }
  return String(describing: action).split(separator: "(").first.map(String.init)
}

/// The smallest JSON value `schema` accepts: empty strings and arrays, zeros, `false`, nulls.
func sampleArguments(_ schema: HarnessJSONSchema) -> Data? {
  func sample(_ schema: HarnessJSONSchema) -> Any {
    switch schema {
    case let .string(_, choices, minLength, _): return choices?.first ?? String(repeating: "a", count: minLength ?? 0)
    case .number, .integer: return 0
    case let .boundedNumber(range): return range.lowerBound
    case .boolean: return false
    case let .object(properties): return properties.mapValues(sample)
    case .array: return [Any]()
    case .nullable: return NSNull()
    }
  }
  return try? JSONSerialization.data(withJSONObject: sample(schema), options: [.fragmentsAllowed])
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
