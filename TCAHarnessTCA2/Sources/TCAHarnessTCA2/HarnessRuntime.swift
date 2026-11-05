import ComposableArchitecture
import Foundation
import TCAHarness

/// Mounts descriptors against an existing live store. Models and transport stay outside.
@MainActor
public final class HarnessRuntime<State, Action> {
  private let descriptor: FeatureDescriptor<State, Action>
  private let store: Store<State, Action>
  private let verify: (State, String) -> Bool?
  private let graph = RuntimeGraph()
  private let timeline: HarnessTimeline?

  /// Pass the timeline given to the root feature's `.harnessTimeline(_:)` to serve `tca devtools`.
  public init(store: Store<State, Action>, descriptor: FeatureDescriptor<State, Action>,
    verify: @escaping (State, String) -> Bool? = { _, _ in nil }, timeline: HarnessTimeline? = .shared) {
    self.store = store; self.descriptor = descriptor; self.verify = verify
    self.timeline = timeline?.isEnabled == true ? timeline : nil
    self.timeline?.setReaders(observe: { [descriptor] value in
      (value as? State).map(descriptor.observation)
    }, mounts: { [weak self] in
      (self?.inspect() ?? []).map { HarnessTimelineMount(path: $0.path, name: $0.name, operations: $0.operations.map(\.label)) }
    })
  }

  public lazy var session = HarnessSession(snapshot: { [weak self] in self?.snapshot() ?? .null },
    offers: { [weak self] in self?.offers() ?? [] },
    verify: { [weak self] condition in
      guard let self else { return nil }; return self.verify(self.store.state, condition)
    }, inspect: { [weak self] in self?.inspect() ?? [] },
    diagnostics: { [weak self] in self?.diagnostics ?? ["Runtime was released; retain the StoreHarness attachment alongside the store"] },
    timeline: timeline.map { timeline in { timeline.page(since: $0) } })

  public func snapshot() -> HarnessValue { descriptor.observation(store.state) }
  public func offers() -> [HarnessOffer] {
    refresh()
    guard let timeline else { return graph.offers }
    let store = self.store
    return graph.offers.map { offer in
      offer.intercepting { candidate, perform in
        let first = timeline.currentIndex
        let previous = store.state
        let operation = try timeline.asAgent(candidate.id, perform)
        // Bindings and dismissals write state without an action; record them so the agent's step
        // is visible: `binding.<path>`, or `dismiss.<feature path>`.
        if timeline.currentIndex == first {
          timeline.asAgent(candidate.id) {
            var route = candidate.id.split(separator: "@")[0].split(separator: "/").dropFirst().map(String.init)
            let kind = route.last == "dismiss" ? route.removeLast() : "binding"
            timeline.recordWrite(path: [kind] + route, state: store.state, previous: previous)
          }
        }
        return operation
      }
    }
  }
  public func inspect() -> [HarnessFeatureInfo] { refresh(); return graph.features }
  public var diagnostics: [String] { refresh(); return graph.diagnostics }

  private func refresh() {
    graph.begin()
    let store = self.store
    descriptor.mount(MountContext(path: "root", parent: nil, resolve: { store }), graph: graph)
    graph.finish()
  }
}

@MainActor
final class RuntimeGraph {
  struct Lease {
    let instance: String
    let identity: AnyHashable
    let parent: String?
  }
  var leases: [String: Lease] = [:]
  var seen: Set<String> = []
  var features: [HarnessFeatureInfo] = []
  var offers: [HarnessOffer] = []
  var diagnostics: [String] = []

  func begin() { seen = []; features = []; offers = []; diagnostics = [] }
  func diagnose(_ message: String) { if !diagnostics.contains(message) { diagnostics.append(message) } }
  /// The identity is the mounted child store; a re-presented or re-spawned child is a new store
  /// core, so it receives a new instance and stale candidates cannot reach it.
  func lease(path: String, identity: AnyHashable, parent: String?) -> String {
    if !seen.insert(path).inserted { diagnose("Duplicate feature path: \(path)") }
    if let existing = leases[path], existing.identity == identity, existing.parent == parent { return existing.instance }
    let lease = Lease(instance: UUID().uuidString, identity: identity, parent: parent)
    leases[path] = lease
    return lease.instance
  }
  func isCurrent(path: String, instance: String) -> Bool { leases[path]?.instance == instance }
  func add(_ feature: HarnessFeatureInfo, offers: [HarnessOffer]) {
    features.append(feature); self.offers += offers
  }
  func finish() {
    for path in Array(leases.keys) where !seen.contains(path) { leases[path] = nil }
    var ids = Set<String>()
    for offer in offers where !ids.insert(offer.candidate.id).inserted {
      diagnose("Duplicate operation: \(offer.candidate.id)")
    }
    // Configuration errors must not make an arbitrary duplicate executable.
    if !diagnostics.isEmpty { offers = []; features = [] }
  }
}
