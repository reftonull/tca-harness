import Foundation
import TCAHarness

/// Mounts descriptors against an existing live store. Models and transport stay outside.
@MainActor
public final class HarnessRuntime<State, Action> {
  private let descriptor: FeatureDescriptor<State, Action>
  private let read: () -> State
  private let send: (Action) -> Void
  private let verify: (State, String) -> Bool?
  private let timeline: HarnessTimeline?
  private let graph = RuntimeGraph()

  public init(descriptor: FeatureDescriptor<State, Action>, read: @escaping () -> State,
    send: @escaping (Action) -> Void, verify: @escaping (State, String) -> Bool? = { _, _ in nil },
    timeline: HarnessTimeline? = nil) {
    self.descriptor = descriptor; self.read = read; self.send = send; self.verify = verify
    self.timeline = timeline?.isEnabled == true ? timeline : nil
    if let timeline = self.timeline {
      // Each entry shows the features and operations mounted after that action.
      // Projected entries use the descriptor's observation, the same view agents get.
      timeline.setReaders(observe: { [descriptor] value in
        (value as? State).map { descriptor.observation($0).json }
      }, mounts: { [descriptor] value in
        guard let state = value as? State else { return nil }
        let graph = RuntimeGraph()
        graph.begin()
        descriptor.mount(MountContext(path: "root", parent: nil, read: { state }, send: { _ in }), graph: graph)
        graph.finish()
        return graph.features.map { HarnessTimelineMount(path: $0.path, name: $0.name, operations: $0.operations.map(\.label)) }
      })
    }
  }

  public lazy var session = HarnessSession(snapshot: { [weak self] in self?.snapshot() ?? .null },
    offers: { [weak self] in self?.offers() ?? [] },
    verify: { [weak self] condition in
      guard let self else { return nil }; return self.verify(self.read(), condition)
    }, inspect: { [weak self] in self?.inspect() ?? [] },
    diagnostics: { [weak self] in self?.diagnostics ?? ["Runtime was released; retain the StoreHarness attachment alongside the store"] },
    timeline: timeline.map { timeline in { timeline.page(since: $0) } })

  public func snapshot() -> HarnessValue { descriptor.observation(read()) }
  public func offers() -> [HarnessOffer] {
    refresh()
    guard let timeline else { return graph.offers }
    return graph.offers.map { $0.intercepting { candidate, perform in try timeline.asAgent(candidate.id, perform) } }
  }
  public func inspect() -> [HarnessFeatureInfo] { refresh(); return graph.features }
  public var diagnostics: [String] { refresh(); return graph.diagnostics }

  private func refresh() {
    graph.begin()
    let read = self.read
    descriptor.mount(MountContext(path: "root", parent: nil, read: { read() }, send: send), graph: graph)
    graph.finish()
  }
}

@MainActor
final class RuntimeGraph {
  struct Lease {
    let instance: String
    let identity: AnyHashable?
    let parent: String?
  }
  var leases: [String: Lease] = [:]
  var seen: Set<String> = []
  var features: [HarnessFeatureInfo] = []
  var offers: [HarnessOffer] = []
  var diagnostics: [String] = []

  func begin() { seen = []; features = []; offers = []; diagnostics = [] }
  func lease(path: String, identity: AnyHashable?, parent: String?) -> String {
    if !seen.insert(path).inserted { diagnostics.append("Duplicate feature path: \(path)") }
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
      diagnostics.append("Duplicate operation: \(offer.candidate.id)")
    }
    // Configuration errors must not make an arbitrary duplicate executable.
    if !diagnostics.isEmpty { offers = []; features = [] }
  }
}
