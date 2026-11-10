import ComposableArchitecture
import Foundation
import TCAHarness

/// "Find books": searches the server's catalog. Each submitted search sends `GET /catalog?q=`;
/// a newer search cancels the one in flight, so a slow response for an older query can't replace
/// the results of the current one. The `stale-search` bug drops that cancellation.
@HarnessFeature
@Reducer
public struct Discover {
  @ObservableState
  public struct State: Equatable {
    /// What's in the search field.
    public var query = ""
    public var results: [CatalogEntry] = []
    /// The query `results` answer; the list header reads "Results for …".
    public var resultsFor = ""
    public var isSearching = false
    public var error: String?
    public init() {}
  }

  public enum Action {
    @HarnessIgnore case searchSubmitted(String)
    @HarnessIgnore case searchResponse(query: String, Result<[CatalogEntry], Error>)
    @HarnessIgnore case closeButtonTapped
  }

  enum CancelID { case search }

  @Dependency(\.api) var api
  @Dependency(\.dismiss) var dismiss
  @Dependency(\.shelfBugs) var bugs

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .searchSubmitted(query):
        state.query = query
        state.error = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
          state.isSearching = false
          state.results = []
          state.resultsFor = query
          return .cancel(id: CancelID.search)
        }
        state.isSearching = true
        let search = Effect<Action>.run { send in
          await send(.searchResponse(query: query, Result { try await api.searchCatalog(query) }))
        }
        // The stale-search bug: every response is applied, in whatever order they arrive.
        return bugs.contains(.staleSearch) ? search : search.cancellable(id: CancelID.search, cancelInFlight: true)

      case let .searchResponse(query, .success(results)):
        state.isSearching = false
        state.results = results
        state.resultsFor = query
        return .none

      case let .searchResponse(_, .failure(error)):
        state.isSearching = false
        state.error = error.localizedDescription
        return .none

      case .closeButtonTapped:
        return .run { _ in await dismiss() }
      }
    }
  }
}
