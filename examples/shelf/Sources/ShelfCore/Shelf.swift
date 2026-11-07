import ComposableArchitecture
import Foundation
import TCAHarnessTCA1

/// The reading list: loads books, shows an unread badge and a "new" dot, searches, and presents the
/// Add book sheet and a book's detail. It owns the list, so it performs saves.
///
/// The harness descriptor (operations, availability, invariants) is in `ShelfHarness.swift`.
@HarnessFeature
@Reducer
public struct Shelf {
  @ObservableState
  public struct State: Equatable {
    public var books: [Book] = []
    /// What the list shows: `books` filtered by the applied (debounced) search.
    public var visibleBooks: [Book] = []
    public var isLoading = false
    public var loadError: String?
    public var unreadCount = 0
    /// The "new" dot, cleared once the user has seen the shelf.
    public var hasNewBooks = true
    public var searchQuery = ""
    public var appliedQuery = ""
    /// Save requests that haven't answered yet.
    public var savesInFlight = 0
    @Presents public var addBook: AddBook.State?
    @Presents public var detail: BookDetail.State?

    public init() {}

    /// Rows a user can tap: none while a sheet covers the list.
    public var rows: IdentifiedArrayOf<Book> {
      guard addBook == nil, detail == nil else { return [] }
      return IdentifiedArray(visibleBooks, uniquingIDsWith: { first, _ in first })
    }

    mutating func booksChanged(recount: Bool = true) {
      if recount { unreadCount = books.filter { !$0.isRead }.count }
      let query = appliedQuery.trimmingCharacters(in: .whitespaces)
      visibleBooks = query.isEmpty ? books : books.filter {
        $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query)
      }
    }
  }

  @CasePathable
  public enum BookRowAction: Equatable {
    case tapped
  }

  public enum Action {
    /// Sent by the view's `.task` (and by the headless host at launch).
    @HarnessIgnore case task
    /// Sent by the view's `.onAppear`.
    @HarnessIgnore case markShelfSeen
    @HarnessIgnore case refreshButtonTapped
    @HarnessIgnore case retryButtonTapped
    @HarnessIgnore case addButtonTapped
    @HarnessIgnore case searchQueryChanged(String)
    @HarnessIgnore case searchDebounced
    @HarnessIgnore case bookRows(IdentifiedAction<UUID, BookRowAction>)
    @HarnessIgnore case booksResponse(Result<[Book], Error>)
    @HarnessIgnore case saveResponse(Result<Book, Error>)
    @HarnessIgnore case addBook(PresentationAction<AddBook.Action>)
    @HarnessIgnore case detail(PresentationAction<BookDetail.Action>)
  }

  enum CancelID { case load, search }

  @Dependency(\.analytics) var analytics
  @Dependency(\.api) var api
  @Dependency(\.continuousClock) var clock
  @Dependency(\.shelfBugs) var bugs

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        if !bugs.contains(.viewOnlySeen) {
          state.hasNewBooks = false
        }
        return load(&state)

      case .markShelfSeen:
        state.hasNewBooks = false
        return .none

      case .refreshButtonTapped, .retryButtonTapped:
        return load(&state)

      case let .booksResponse(.success(books)):
        state.isLoading = false
        state.loadError = nil
        state.books = books
        state.booksChanged()
        return .none

      case let .booksResponse(.failure(error)):
        state.isLoading = false
        state.loadError = error.localizedDescription
        return .none

      case .addButtonTapped:
        state.addBook = AddBook.State()
        return .none

      case let .searchQueryChanged(query):
        state.searchQuery = query
        let debounce = Effect<Action>.run { send in
          try await clock.sleep(for: .milliseconds(300))
          await send(.searchDebounced)
        }
        .cancellable(id: CancelID.search, cancelInFlight: true)
        guard bugs.contains(.chattySearch) else { return debounce }
        return .merge(debounce, .run { _ in try? await analytics.track("search_typed", ["query": query]) })

      case .searchDebounced:
        state.appliedQuery = state.searchQuery
        state.booksChanged(recount: false)
        let query = state.appliedQuery
        guard !query.isEmpty else { return .none }
        return .run { _ in try? await analytics.track("search", ["query": query]) }

      case let .bookRows(.element(id, .tapped)):
        guard let book = state.books.first(where: { $0.id == id }) else { return .none }
        state.detail = BookDetail.State(book: book)
        return .none

      case let .addBook(.presented(.delegate(.save(book)))):
        state.savesInFlight += 1
        state.addBook?.isSaving = true
        state.addBook?.saveError = nil
        return .run { send in
          // The server echoes the book; we keep ours, which carries the id we chose.
          await send(.saveResponse(Result { _ = try await api.createBook(book); return book }))
        }

      case let .saveResponse(.success(book)):
        state.savesInFlight -= 1
        state.books.append(book)
        state.booksChanged()
        state.addBook?.isSaving = false
        state.addBook?.isSaved = true
        return .run { _ in try? await analytics.track("book_added", [:]) }

      case let .saveResponse(.failure(error)):
        state.savesInFlight -= 1
        // Without this the editor keeps spinning: no error, no retry, no way to close it.
        if bugs.contains(.stuckSave) { return .none }
        state.addBook?.isSaving = false
        state.addBook?.saveError = error.localizedDescription
        return .none

      case let .detail(.presented(.delegate(.updated(book)))):
        if let index = state.books.firstIndex(where: { $0.id == book.id }) {
          state.books[index] = book
        }
        state.booksChanged(recount: !bugs.contains(.badgeDrift))
        return .none

      case let .detail(.presented(.delegate(.deleted(id)))):
        state.books.removeAll { $0.id == id }
        state.booksChanged()
        state.detail = nil
        return .none

      case let .detail(.presented(.delegate(.deleteInBackground(id)))):
        state.books.removeAll { $0.id == id }
        state.booksChanged()
        state.detail = nil
        // The detail is gone, but its response is still routed to it.
        return .run { send in
          await send(.detail(.presented(.deleteResponse(Result { try await api.deleteBook(id); return id }))))
        }

      case .addBook, .detail:
        return .none
      }
    }
    .ifLet(\.$addBook, action: \.addBook) { AddBook() }
    .ifLet(\.$detail, action: \.detail) { BookDetail() }
  }

  private func load(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.loadError = nil
    return .run { send in
      await send(.booksResponse(Result { try await api.fetchBooks() }))
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}
