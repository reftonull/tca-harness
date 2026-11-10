import ComposableArchitecture
import Foundation
import TCAHarness

/// One book: mark it read, or delete it. Operations are declared in `ShelfHarness.swift`.
@HarnessFeature
@Reducer
public struct BookDetail {
  @ObservableState
  public struct State: Equatable {
    public var book: Book
    public var isUpdating = false
    public var isDeleting = false
    public var error: String?

    public init(book: Book) { self.book = book }

    public var isBusy: Bool { isUpdating || isDeleting }
  }

  public enum Action {
    @HarnessIgnore case markReadButtonTapped
    @HarnessIgnore case deleteButtonTapped
    @HarnessIgnore case closeButtonTapped
    @HarnessIgnore case updateResponse(Result<Book, Error>)
    @HarnessIgnore case deleteResponse(Result<UUID, Error>)
    @HarnessIgnore case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable {
      case updated(Book)
      case deleted(UUID)
      /// Close now and let the shelf finish the delete (only with the `late-delete` bug).
      case deleteInBackground(UUID)
    }
  }

  @Dependency(\.api) var api
  @Dependency(\.dismiss) var dismiss
  @Dependency(\.shelfBugs) var bugs

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .markReadButtonTapped:
        guard !state.isBusy, !state.book.isRead else { return .none }
        state.isUpdating = true
        state.error = nil
        var book = state.book
        book.isRead = true
        return .run { [book] send in
          // The server echoes the book; we keep our copy, which is what we asked it to store.
          await send(.updateResponse(Result { _ = try await api.updateBook(book); return book }))
        }

      case let .updateResponse(.success(book)):
        state.isUpdating = false
        state.book = book
        return .send(.delegate(.updated(book)))

      case let .updateResponse(.failure(error)):
        state.isUpdating = false
        state.error = error.localizedDescription
        return .none

      case .deleteButtonTapped:
        guard !state.isBusy else { return .none }
        state.isDeleting = true
        state.error = nil
        let id = state.book.id
        if bugs.contains(.lateDelete) {
          // "Feels faster": leave now, and have the shelf send the response back here when it lands.
          return .send(.delegate(.deleteInBackground(id)))
        }
        return .run { send in
          await send(.deleteResponse(Result { try await api.deleteBook(id); return id }))
        }

      case let .deleteResponse(.success(id)):
        state.isDeleting = false
        return .send(.delegate(.deleted(id)))

      case let .deleteResponse(.failure(error)):
        state.isDeleting = false
        state.error = error.localizedDescription
        return .none

      case .closeButtonTapped:
        guard !state.isBusy else { return .none }
        return .run { _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }
}
