import CasePaths
import ComposableArchitecture
import Foundation
import TCAHarness

private protocol CasePayload { static var payloadType: Any.Type { get } }
extension Case: CasePayload { static var payloadType: Any.Type { Value.self } }

struct ActionLeaf {
  let route: [String]
  let statePath: [String]
  let action: Any
}

struct ActionNode {
  let typeID: ObjectIdentifier
  let route: [String]
  let statePath: [String]
  let embed: (Any) -> Any?
}

struct ActionCatalog {
  var leaves: [ActionLeaf] = []
  var nodes: [ActionNode] = []
}

private protocol SpecialActions { static func discover(depth: Int) -> ActionCatalog }
extension PresentationAction: SpecialActions where Action: CasePathable {
  static func discover(depth: Int) -> ActionCatalog {
    let child = discoverActions(Action.self, depth: depth + 1)
    return ActionCatalog(
      leaves: [ActionLeaf(route: ["dismiss"], statePath: [], action: Self.dismiss)] + child.leaves.map {
        ActionLeaf(route: ["presented"] + $0.route, statePath: $0.statePath, action: Self.presented($0.action as! Action))
      },
      nodes: child.nodes.map { node in
        ActionNode(typeID: node.typeID, route: ["presented"] + node.route, statePath: node.statePath,
          embed: { value in (node.embed(value) as? Action).map(Self.presented) })
      }
    )
  }
}

private func caseName(_ value: Any) -> String {
  Mirror(reflecting: value).children.first?.label ?? String(describing: value)
}

func discoverActions<Action: CasePathable>(_ actionType: Action.Type, depth: Int = 0) -> ActionCatalog {
  guard depth < 9 else { return ActionCatalog() }
  if let special = actionType as? any SpecialActions.Type { return special.discover(depth: depth) }
  guard let sequence = Action.allCasePaths as? any Sequence else { return ActionCatalog() }
  var result = ActionCatalog(nodes: [ActionNode(typeID: ObjectIdentifier(actionType), route: [], statePath: [], embed: { $0 as? Action })])
  for raw in sequence {
    guard let path = raw as? PartialCaseKeyPath<Action> else { continue }
    if let action = path(()) {
      result.leaves.append(ActionLeaf(route: [caseName(action)], statePath: [], action: action))
      continue
    }
    guard let payload = Swift.type(of: path).valueType as? any CasePayload.Type else { continue }
    if let finite = payload.payloadType as? any CaseIterable.Type {
      for value in finiteValues(finite) {
        if let action = path(value) {
          result.leaves.append(ActionLeaf(route: [caseName(action), String(describing: value)], statePath: [], action: action))
        }
      }
      continue
    }
    guard let nested = payload.payloadType as? any CasePathable.Type else { continue }
    let child = discoverActions(nested, depth: depth + 1)
    guard let sample = child.leaves.first?.action, let parentSample = path(sample) else { continue }
    let name = caseName(parentSample)
    result.leaves += child.leaves.compactMap { leaf in
      path(leaf.action).map { ActionLeaf(route: [name] + leaf.route, statePath: [name] + leaf.statePath, action: $0) }
    }
    result.nodes += child.nodes.map { node in
      ActionNode(typeID: node.typeID, route: [name] + node.route, statePath: [name] + node.statePath,
        embed: { value in node.embed(value).flatMap { path($0) } })
    }
  }
  return result
}

/// Runtime case-path discovery and checked nested action construction for TCA 1.
/// Structural state/action paths must align. Unusual layouts need an adapter.
@MainActor
public final class DiscoveredHarness<State, Action: CasePathable> {
  private let read: () -> State
  private let send: (Action) -> Void
  private let catalog: ActionCatalog
  private let allow: (String) -> Bool
  private var stateOverrides: [String: () -> Any?] = [:]
  private struct Lifetime {
    var identity: ObservableStateID?
    var present = false
    var generation = 0
  }
  private var lifetimes: [String: Lifetime] = [:]
  private var bindings: [ObjectIdentifier: (Any, [String], @escaping (Any) -> Void) -> [HarnessOffer]] = [:]

  public init(read: @escaping () -> State, send: @escaping (Action) -> Void,
    allow: @escaping (String) -> Bool = { $0.split(separator: "/").contains { $0.hasSuffix("ButtonTapped") } || $0.hasSuffix("/dismiss") }) {
    self.read = read
    self.send = send
    self.allow = allow
    catalog = discoverActions(Action.self)
  }

  public var discoveredActionPaths: [String] { catalog.leaves.map { $0.route.joined(separator: "/") } }
  public var discoveredFeaturePaths: [String] { catalog.nodes.map { $0.statePath.joined(separator: "/") } }
  public var redactedFields: Set<String> = ["token", "accessToken", "refreshToken", "password", "apiKey", "authorization"]
  public func snapshot() -> HarnessValue { StateInspection.snapshot(read(), redacting: redactedFields) }

  /// For computed or unusually named scopes, supply the state projection once.
  /// Nested action embedding is still discovered automatically.
  public func registerState(path: [String], read: @escaping () -> Any?) {
    stateOverrides[path.joined(separator: "/")] = read
  }

  private func currentState(_ path: [String]) -> Any? {
    if let override = stateOverrides[path.joined(separator: "/")] { return override() }
    return stateAtPath(read(), path)
  }

  private func generation(_ path: [String]) -> Int {
    let key = path.joined(separator: "/")
    let current = currentState(path)
    let identity = (current as? any ObservableState)?._$id
    var lifetime = lifetimes[key] ?? Lifetime()
    if current != nil && (!lifetime.present || identity != lifetime.identity) { lifetime.generation += 1 }
    lifetime.present = current != nil
    lifetime.identity = identity
    lifetimes[key] = lifetime
    return lifetime.generation
  }

  /// One writable group per feature type, not one closure per field or parent route.
  public func registerBindings<ChildState: ObservableState, ChildAction: BindableAction & CasePathable, Value: Codable & Equatable & Sendable>(
    state: ChildState.Type, action: ChildAction.Type,
    field: WritableKeyPath<ChildState, Value> & Sendable, name: String,
    numericRanges: [String: ClosedRange<Double>] = [:]
  ) where ChildAction.State == ChildState {
    bindings[ObjectIdentifier(ChildAction.self)] = { current, route, dispatch in
      guard let state = current as? ChildState else { return [] }
      return CodableBindings.offers(value: state[keyPath: field], prefix: (route + ["binding", name]).joined(separator: "/"),
        numericRanges: numericRanges) { value in
        dispatch(ChildAction.binding(.set(field, value)))
      }
    }
  }

  public func offers() -> [HarnessOffer] {
    // Observe missing nodes as well as present ones, so dismissal invalidates routes.
    for node in catalog.nodes { _ = generation(node.statePath) }
    var result = catalog.leaves.compactMap { leaf -> HarnessOffer? in
      let id = leaf.route.joined(separator: "/")
      guard allow(id), currentState(leaf.statePath) != nil else { return nil }
      let generation = generation(leaf.statePath)
      let scopedID = leaf.statePath.isEmpty ? id : id + "#\(generation)"
      return HarnessOffer(id: scopedID, feature: leaf.statePath.joined(separator: "/"), label: id) { [weak self, send] in
        guard self?.currentState(leaf.statePath) != nil else { return .init { .cancelled } }
        send(leaf.action as! Action)
        return .completed
      }
    }
    for node in catalog.nodes {
      guard let provider = bindings[node.typeID], let child = currentState(node.statePath) else { continue }
      let scopedRoute = node.route + ["@\(generation(node.statePath))"]
      result += provider(child, scopedRoute) { [send] value in
        if let root = node.embed(value) as? Action { send(root) }
      }
    }
    return result
  }
}

private func finiteValues<T: CaseIterable>(_ type: T.Type) -> [Any] { T.allCases.map { $0 as Any } }
