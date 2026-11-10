import ComposableArchitecture
import Foundation

/// A catalog search result (`GET /catalog?q=`), not on the shelf.
public struct CatalogEntry: Codable, Equatable, Sendable {
  public var title: String
  public var author: String
  public init(title: String, author: String) { self.title = title; self.author = author }
}

public struct Book: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var author: String
  public var isRead: Bool
  public var addedAt: Date

  public init(id: UUID, title: String, author: String, isRead: Bool = false, addedAt: Date) {
    self.id = id
    self.title = title
    self.author = author
    self.isRead = isRead
    self.addedAt = addedAt
  }
}

/// Bugs planted on purpose, one per testing pattern. Enabled with `SHELF_BUGS` (a comma-separated
/// list, or `all`). Each is a single `if bugs.contains(...)` in a reducer or view; off by default.
public enum ShelfBug: String, CaseIterable, Sendable {
  /// A failed save leaves the editor spinning with no error and no way out. Caught by `tca chaos`.
  case stuckSave = "stuck-save"
  /// Save is not disabled (or guarded) while its request is in flight; a double tap adds the book
  /// twice. Only a tap during the request reaches it: `tca explore --races` with replay latency.
  case doubleSave = "double-save"
  /// Marking a book read doesn't update the unread badge. Invariant.
  case badgeDrift = "badge-drift"
  /// Search sends an analytics event per keystroke instead of per search. Network budget.
  case chattySearch = "chatty-search"
  /// New books are stamped with `Date()` instead of the `date` dependency. `tca determinism`.
  case wallClock = "wall-clock"
  /// Only the SwiftUI view clears the "new" dot (in `.onAppear`). `tca diff` headless vs ui.
  case viewOnlySeen = "view-only-seen"
  /// Delete closes the detail first and routes the response to it after it's gone. Issue oracle.
  case lateDelete = "late-delete"
  /// Reading stats (a vanilla `@Observable` model): a failed load leaves the spinner on, with no
  /// error and no Retry. Caught by `tca chaos journeys/view-stats.toml` (stranded).
  case statsStuck = "stats-stuck"
  /// Reading goal (a vanilla model): saving doesn't recompute the progress percentage. Invariant.
  case goalDrift = "goal-drift"
  /// Find books: a search doesn't cancel the one in flight, so a slow older response overwrites a
  /// newer one ("Du" results under "Dune"). `tca chaos --reorder journeys/discover.toml`.
  case staleSearch = "stale-search"
  /// Server-side: `server.py --v2` renames `author` to `writer`. Contract check at rung 3.
  /// Listed so `SHELF_BUGS=all` parses; the app has no code for it.
  case v2Contract = "v2-contract"
}

public struct ShelfBugs: Sendable, Equatable {
  public var enabled: Set<ShelfBug>
  public init(_ enabled: Set<ShelfBug> = []) { self.enabled = enabled }
  public func contains(_ bug: ShelfBug) -> Bool { enabled.contains(bug) }

  /// Parses `SHELF_BUGS`: `all`, or a comma-separated list of raw values. Unknown names are ignored.
  public static func parse(_ value: String?) -> Self {
    let names = (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    if names.contains("all") { return Self(Set(ShelfBug.allCases)) }
    return Self(Set(names.compactMap(ShelfBug.init(rawValue:))))
  }

  public static var fromEnvironment: Self { parse(ProcessInfo.processInfo.environment["SHELF_BUGS"]) }
}

extension ShelfBugs: DependencyKey {
  public static var liveValue: ShelfBugs { .fromEnvironment }
  public static var testValue: ShelfBugs { ShelfBugs() }
}

extension DependencyValues {
  public var shelfBugs: ShelfBugs {
    get { self[ShelfBugs.self] }
    set { self[ShelfBugs.self] = newValue }
  }
}
