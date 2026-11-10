import Foundation
#if DEBUG
@preconcurrency import Network
#endif
import Observation

/// Local, unauthenticated JSON-lines transport for a harness session.
///
/// Binds only IPv4 loopback, and only after the app explicitly calls ``start(port:)``.
/// The listener exists only in builds compiled with `DEBUG` (SwiftPM's and Xcode's debug
/// configuration). In other builds the type keeps the same API, but ``start(port:)`` throws
/// and no network code is compiled in.
@Observable
@MainActor
public final class HarnessServer {
  /// Human-readable listener state, for display in a debug UI.
  public private(set) var status = "Stopped"
  /// Number of requests handled since the server was created.
  public private(set) var requestCount = 0
  @ObservationIgnored private let handler: @MainActor (Data) async -> Data
  @ObservationIgnored private var runWaiter: CheckedContinuation<Void, Never>?
#if DEBUG
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var peers: [UUID: Peer] = [:]

  private final class Peer {
    let connection: NWConnection
    var buffer = Data()
    init(_ connection: NWConnection) { self.connection = connection }
  }

#endif

  /// Creates a stopped server. `handler` receives one request line and returns one response line,
  /// usually `HarnessSession.handleJSON`.
  public init(handler: @escaping @MainActor (Data) async -> Data) {
    self.handler = handler
  }

  /// Whether this build contains the listener. False when compiled without `DEBUG`.
  public nonisolated static var isAvailable: Bool {
#if DEBUG
    true
#else
    false
#endif
  }

  /// Starts listening on `127.0.0.1:port`. Does nothing if already started.
  ///
  /// - Throws: If `port` is 0, if the listener cannot be created, or, in builds compiled
  ///   without `DEBUG`, always (no listener is available).
  public func start(port: UInt16 = 8765) throws {
#if !DEBUG
    throw NSError(domain: "TCAHarness", code: 2, userInfo: [
      NSLocalizedDescriptionKey: "HarnessServer is only available in DEBUG builds",
    ])
#else
    guard listener == nil else { return }
    guard let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else {
      throw NSError(domain: "TCAHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
    }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .ready: self?.status = "Listening on 127.0.0.1:\(port)"
        case let .failed(error):
          self?.stop()
          self?.status = "Listener failed: \(error.localizedDescription)"
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.start(queue: .main)
#endif
  }

  /// Stops listening and closes open connections. Also ends a pending ``run(port:onReady:)``.
  public func stop() {
#if DEBUG
    listener?.cancel()
    listener = nil
    for peer in peers.values { peer.connection.cancel() }
    peers.removeAll()
#endif
    status = "Stopped"
    runWaiter?.resume()
    runWaiter = nil
  }

  /// Starts listening on `127.0.0.1:port`, waits until the listener is ready, calls `onReady`,
  /// then suspends until ``stop()`` is called or the calling task is cancelled.
  ///
  /// Use this to host a store with no UI: the process stays alive serving requests on the main
  /// actor for as long as this call is suspended.
  ///
  /// - Throws: If `port` is invalid or unavailable, if the listener does not become ready within
  ///   five seconds, or, in builds compiled without `DEBUG`, always (no listener is available).
  public func run(port: UInt16 = 8765, onReady: () -> Void = {}) async throws {
#if !DEBUG
    throw NSError(domain: "TCAHarness", code: 2, userInfo: [
      NSLocalizedDescriptionKey: "Headless hosting needs the harness listener, which is compiled only in DEBUG builds. "
        + "Build with the debug configuration (`swift build`), or add `-Xswiftc -DDEBUG` to an optimized build.",
    ])
#else
    try start(port: port)
    var ready = false
    for _ in 0..<500 {
      if status.hasPrefix("Listening") { ready = true; break }
      // `stop()` before readiness was observed is a normal end; a failed listener reports its error.
      if listener == nil { if status == "Stopped" { return }; break }
      // Cancellation while starting ends the host the same way as cancellation while running.
      if Task.isCancelled { stop(); return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard ready else {
      let reason = status
      stop()
      throw NSError(domain: "TCAHarness", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Harness listener on 127.0.0.1:\(port) did not start (\(reason))",
      ])
    }
    onReady()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if listener == nil || Task.isCancelled { continuation.resume() } else { runWaiter = continuation }
      }
    } onCancel: {
      Task { @MainActor in self.stop() }
    }
#endif
  }

#if DEBUG
  private func accept(_ connection: NWConnection) {
    let id = UUID()
    peers[id] = Peer(connection)
    connection.start(queue: .main)
    receive(id)
  }

  private func receive(_ id: UUID) {
    guard let peer = peers[id] else { return }
    peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, let peer = self.peers[id] else { return }
        if let data { peer.buffer.append(data) }
        // Bound request size; a remote client cannot grow an unlimited input buffer.
        guard peer.buffer.count <= 65536 else {
          peer.connection.cancel()
          self.peers[id] = nil
          return
        }
        while let newline = peer.buffer.firstIndex(of: 10) {
          let request = Data(peer.buffer[..<newline])
          peer.buffer.removeSubrange(...newline)
          self.requestCount += 1
          var response = await self.handler(request)
          response.append(10)
          peer.connection.send(content: response, completion: .contentProcessed { _ in })
        }
        if complete || error != nil {
          peer.connection.cancel()
          self.peers[id] = nil
        } else {
          self.receive(id)
        }
      }
    }
  }
#endif
}
