import Foundation
import Observation

/// "Reading stats", written the way a team without TCA writes a screen: an `@Observable` model with
/// an async method the view calls. Nothing here knows about TCA or the harness.
///
/// The shelf hosts it in its store with `Hosted<StatsModel>` (see `Shelf.swift`), so its calls run as
/// effects, show in the devtools timeline and are cancelled when the sheet is dismissed. Its harness
/// descriptor is in `ShelfHarness.swift`.
@MainActor @Observable
public final class StatsModel {
  public private(set) var summary: ReadingStats?
  public private(set) var isLoading = false
  public private(set) var error: String?

  private let api: ReadingAPI

  nonisolated public init(api: ReadingAPI = .live) { self.api = api }

  /// Loads `GET /stats`. On failure the previous numbers stay and an error with Retry is shown.
  public func load() async {
    isLoading = true
    error = nil
    do {
      summary = try await api.fetchStats()
      isLoading = false
    } catch {
      // Only the success path clears the spinner (the fix is `defer { isLoading = false }`), so a
      // failed request leaves it spinning: no error, no Retry, Refresh disabled.
      if ShelfBugs.fromEnvironment.contains(.statsStuck) { return }
      isLoading = false
      self.error = error.localizedDescription
    }
  }
}
