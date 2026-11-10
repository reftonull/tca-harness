import ComposableArchitecture
import Foundation

extension DependencyValues {
  /// Makes `uuid`, `date` and `withRandomNumberGenerator` reproducible when the run asks for it
  /// with `TCA_HARNESS_SEED` (an integer; other text is hashed into a seed). Without the variable,
  /// and in builds compiled without `DEBUG`, this does nothing.
  ///
  /// ```swift
  /// let store = Store(initialState: App.State()) { App().harnessTimeline() } withDependencies: {
  ///   $0.harnessDeterministic()
  /// }
  /// ```
  public mutating func harnessDeterministic(environment: [String: String] = ProcessInfo.processInfo.environment) {
#if DEBUG
    guard let text = environment["TCA_HARNESS_SEED"]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
    harnessDeterministic(seed: UInt64(text) ?? Int64(text).map { UInt64(bitPattern: $0) } ?? fnv1a(text))
#endif
  }

  /// Makes `uuid` incrementing (`00000000-0000-0000-0000-000000000000`, then `…001`), `date` a
  /// constant ``HarnessDeterministic/startDate`` and `withRandomNumberGenerator` a generator seeded with `seed`.
  public mutating func harnessDeterministic(seed: UInt64) {
    uuid = .incrementing
    date = .constant(HarnessDeterministic.startDate)
    withRandomNumberGenerator = WithRandomNumberGenerator(HarnessRandomNumberGenerator(seed: seed))
  }
}

public enum HarnessDeterministic {
  /// The fixed `date` of deterministic runs: 2026-01-01T00:00:00Z.
  public static let startDate = Date(timeIntervalSince1970: 1_767_225_600)
}

/// A small seeded generator (SplitMix64). Same seed, same sequence, on every platform.
public struct HarnessRandomNumberGenerator: RandomNumberGenerator, Sendable {
  private var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private func fnv1a(_ text: String) -> UInt64 {
  text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
}
