import ComposableArchitecture
import Foundation
import TCAHarness

/// The "Add book" sheet. The shelf performs the request (it owns the list), so this feature only
/// edits the draft, guards against submitting twice and shows the outcome. After a save the sheet
/// stays up to confirm ("Added to your shelf") until the user taps Done.
///
/// Operations, with their labels and availability, are declared in `ShelfHarness.swift`.
@HarnessFeature
@Reducer
public struct AddBook {
  @ObservableState
  public struct State: Equatable {
    public var draft = Draft()
    public var isSaving = false
    public var saveError: String?
    public var isSaved = false
    /// Assigned on the first save so retries send the same book.
    public var pending: Book?

    public init(draft: Draft = Draft()) { self.draft = draft }

    public var canSubmit: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  public struct Draft: Codable, Equatable, Sendable {
    public var title = ""
    public var author = ""
    public init(title: String = "", author: String = "") { self.title = title; self.author = author }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    @HarnessIgnore case saveButtonTapped
    @HarnessIgnore case retryButtonTapped
    @HarnessIgnore case cancelButtonTapped
    @HarnessIgnore case doneButtonTapped
    @HarnessIgnore case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable {
      case save(Book)
    }
  }

  @Dependency(\.date.now) var now
  @Dependency(\.dismiss) var dismiss
  @Dependency(\.shelfBugs) var bugs
  @Dependency(\.uuid) var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .saveButtonTapped, .retryButtonTapped:
        guard state.canSubmit else { return .none }
        // The submit guard: once the book is in flight or saved, Save does nothing. The double-save
        // bug only checks `isSaved`, so a second tap while the first request is in flight submits the
        // same book again.
        if state.isSaved || (state.isSaving && !bugs.contains(.doubleSave)) { return .none }
        var book = state.pending ?? Book(
          id: uuid(), title: "", author: "",
          addedAt: bugs.contains(.wallClock) ? Date() : now
        )
        book.title = state.draft.title.trimmingCharacters(in: .whitespaces)
        book.author = state.draft.author.trimmingCharacters(in: .whitespaces)
        state.pending = book
        // The shelf sets `isSaving` when it starts the request, in the same reduction.
        return .send(.delegate(.save(book)))

      case .cancelButtonTapped:
        guard !state.isSaving else { return .none }
        return .run { _ in await dismiss() }

      case .doneButtonTapped:
        return .run { _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }
}
