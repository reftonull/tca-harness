import ComposableArchitecture
import Foundation
import TCAHarness

/// Generated features supply their descriptor without requiring read/send closures.
public protocol HarnessFeatureProvider: Reducer {
  @MainActor static var harnessDescriptor: FeatureDescriptor<State, Action> { get }
  /// Adjusts the descriptor `@HarnessFeature` generates, for example to add invariants. Parents that
  /// compose this feature use the adjusted descriptor too.
  ///
  /// ```swift
  /// extension Shelf {
  ///   @MainActor static func customizeHarnessDescriptor(_ descriptor: FeatureDescriptor<State, Action>)
  ///     -> FeatureDescriptor<State, Action> {
  ///     descriptor.invariant("no duplicate books") { Set($0.books.map(\.id)).count == $0.books.count }
  ///   }
  /// }
  /// ```
  @MainActor static func customizeHarnessDescriptor(_ descriptor: FeatureDescriptor<State, Action>) -> FeatureDescriptor<State, Action>
}

extension HarnessFeatureProvider {
  @MainActor public static func customizeHarnessDescriptor(_ descriptor: FeatureDescriptor<State, Action>) -> FeatureDescriptor<State, Action> {
    descriptor
  }
}

/// An agent harness attached to an existing store: a typed runtime plus its loopback transport.
///
/// Create one with `store.harness(...)`, retain it for as long as the store, and call
/// ``startIfEnabled(environment:defaultPort:)``. The harness sends actions through the store you
/// already have; it never creates a second store.
@MainActor
public final class StoreHarness<State, Action> {
  /// Observes the store's state and dispatches the operations the descriptor exposes.
  public let runtime: HarnessRuntime<State, Action>
  /// Loopback JSON-lines transport for ``runtime``. Inert in builds compiled without `DEBUG`.
  public let server: HarnessServer
  /// Captures reported issues into ``HarnessRuntime/issues`` while this attachment exists. Nil without `DEBUG`.
  private let issueReporter: HarnessIssueReporter?

  /// Pass the timeline given to the root reducer's `.harnessTimeline(_:)` to serve `tca devtools`.
  ///
  /// In builds compiled with `DEBUG`, the attachment adds a ``HarnessIssueReporter`` for `issues` to
  /// `IssueReporters.current` (keeping the existing reporters) and removes it when released.
  public init(store: Store<State, Action>, descriptor: FeatureDescriptor<State, Action>,
    verify: @escaping (State, String) -> Bool? = { _, _ in nil }, timeline: HarnessTimeline? = .shared,
    issues: HarnessIssueLog = .shared) {
    let runtime = HarnessRuntime(descriptor: descriptor,
      read: { store.withState { $0 } },
      send: { action in
        if let timeline { timeline.asAgent(nil) { _ = store.send(action) } } else { store.send(action) }
      }, verify: verify, timeline: timeline, issues: issues)
    self.runtime = runtime
    server = HarnessServer { await runtime.session.handleJSON($0) }
    issueReporter = HarnessServer.isAvailable ? HarnessIssueReporter.install(log: issues) : nil
  }

  deinit { issueReporter?.uninstall() }

  /// Starts the loopback listener unconditionally. Prefer ``startIfEnabled(environment:defaultPort:)``.
  ///
  /// - Throws: If the port is invalid or unavailable, and always in builds compiled without `DEBUG`.
  public func start(port: UInt16 = 8765) throws { try server.start(port: port) }

  /// Stops the listener and closes open connections. Also ends a pending ``runHeadless(port:)``.
  public func stop() { server.stop() }

  /// Serves this store with no UI: starts the loopback listener, prints
  /// `TCA harness listening on 127.0.0.1:<port>` to standard error once it accepts connections,
  /// and suspends until ``stop()`` is called or the calling task is cancelled.
  ///
  /// The same descriptor, `tca` CLI and agents work against a headless host as against the app.
  /// Unlike ``startIfEnabled(environment:defaultPort:)`` it does not consult `TCA_HARNESS`:
  /// calling it is the opt-in. The timeline still follows its own `isEnabled`; pass
  /// `HarnessTimeline(isEnabled: true)` to both the reducer and the harness to record without
  /// `TCA_HARNESS=1`.
  ///
  /// ```swift
  /// @main struct Host {
  ///   static func main() async throws {
  ///     let store = Store(initialState: Feature.State()) { Feature().harnessTimeline() }
  ///     try await store.harness(Feature.self).runHeadless(port: 8790)
  ///   }
  /// }
  /// ```
  ///
  /// - Throws: If the port is invalid or in use, and always in builds compiled without `DEBUG`,
  ///   where the listener does not exist; the error says how to build with it.
  public func runHeadless(port: UInt16 = 8765) async throws {
    try await server.run(port: port) {
      FileHandle.standardError.write(Data("TCA harness listening on 127.0.0.1:\(port)\n".utf8))
    }
  }

  /// Starts the loopback listener when the process was launched with `TCA_HARNESS=1`.
  ///
  /// `TCA_HARNESS_PORT` optionally overrides `defaultPort`. Call this once after creating the
  /// store, and keep the returned harness alive for as long as the store.
  ///
  /// In builds compiled without `DEBUG` this does nothing and returns `false`, whatever the
  /// environment says: the listener is not compiled into release builds.
  ///
  /// - Returns: Whether a listener was started.
  /// - Throws: An actionable error when the harness is enabled but the port is malformed or in use.
  @discardableResult
  public func startIfEnabled(environment: [String: String] = ProcessInfo.processInfo.environment,
    defaultPort: UInt16 = 8765) throws -> Bool {
    guard let port = try harnessPort(environment: environment, defaultPort: defaultPort) else { return false }
    try start(port: port)
    return true
  }
}

extension Store {
  /// Attaches an agent harness built from an explicit descriptor.
  ///
  /// Use this for features you cannot annotate with `@HarnessFeature`, such as external packages,
  /// or to adapt a generated descriptor. Retain the result for as long as the store.
  ///
  /// - Parameters:
  ///   - descriptor: The feature tree, operations and observation the agent can see.
  ///   - verify: Answers named `verify` conditions; return `nil` for conditions you do not know.
  ///   - timeline: The timeline passed to the root's `.harnessTimeline(_:)`, served to `tca devtools`.
  ///     Pass `nil` to serve no timeline.
  @MainActor
  public func harness(descriptor: FeatureDescriptor<State, Action>,
    verify: @escaping (State, String) -> Bool? = { _, _ in nil },
    timeline: HarnessTimeline? = .shared, issues: HarnessIssueLog = .shared) -> StoreHarness<State, Action> {
    StoreHarness(store: self, descriptor: descriptor, verify: verify, timeline: timeline, issues: issues)
  }

  /// Attaches an agent harness using the descriptor generated by `@HarnessFeature`.
  ///
  /// ```swift
  /// let harness = store.harness(AppFeature.self)
  /// try harness.startIfEnabled()
  /// ```
  ///
  /// Retain the result for as long as the store. See ``harness(descriptor:verify:timeline:)``
  /// for the parameters.
  @MainActor
  public func harness<Feature: HarnessFeatureProvider>(_ feature: Feature.Type,
    verify: @escaping (State, String) -> Bool? = { _, _ in nil },
    timeline: HarnessTimeline? = .shared, issues: HarnessIssueLog = .shared) -> StoreHarness<State, Action>
  where Feature.State == State, Feature.Action == Action {
    harness(descriptor: Feature.harnessDescriptor, verify: verify, timeline: timeline, issues: issues)
  }
}
