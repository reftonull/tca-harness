import ComposableArchitecture
import Foundation
import TCAHarnessTCA1

/// Everything the harness sees of Shelf, in one place.
///
/// `@HarnessFeature` generates each feature's observation. Operations are declared here rather than
/// with `@HarnessOperation` because they carry availability the views also enforce: a sheet covers
/// the list, and the editor's buttons are disabled while a save is in flight. That availability is
/// what lets `tca chaos` tell "the user can still do something" from "the user is stuck".
public enum ShelfHarness {
  /// The root descriptor to attach: `store.harness(descriptor: ShelfHarness.descriptor)`.
  @MainActor
  public static var descriptor: FeatureDescriptor<Shelf.State, Shelf.Action> {
    let bugs = ShelfBugs.fromEnvironment
    let noSheet: (Shelf.State) -> Bool = { $0.addBook == nil && $0.detail == nil }
    let loading: (Shelf.State) -> HarnessOperationStatus = { $0.isLoading ? .running : .succeeded }

    let addBook = AddBook.harnessDescriptor
      .operation("setTitle", label: "Set title", arguments: String.self,
        action: { .binding(.set(\.draft.title, $0)) }, available: { !$0.isSaving && !$0.isSaved })
      .operation("setAuthor", label: "Set author", arguments: String.self,
        action: { .binding(.set(\.draft.author, $0)) }, available: { !$0.isSaving && !$0.isSaved })
      .operation("save", label: "Save", action: .saveButtonTapped,
        // Mirrors the button: hidden while saving, replaced by Done once saved. The double-save bug
        // leaves it in place.
        available: { $0.canSubmit && $0.saveError == nil && ((!$0.isSaving && !$0.isSaved) || bugs.contains(.doubleSave)) },
        completion: { $0.isSaving ? .running : .succeeded })
      .operation("retry", label: "Retry", action: .retryButtonTapped,
        available: { $0.saveError != nil && !$0.isSaving },
        completion: { $0.isSaving ? .running : .succeeded })
      .operation("cancel", label: "Cancel", action: .cancelButtonTapped, available: { !$0.isSaving && !$0.isSaved })
      .operation("done", label: "Done", action: .doneButtonTapped, available: { $0.isSaved })

    let detail = BookDetail.harnessDescriptor
      .operation("markRead", label: "Mark as read", action: .markReadButtonTapped,
        available: { !$0.isBusy && !$0.book.isRead }, completion: { $0.isUpdating ? .running : .succeeded })
      .operation("delete", label: "Delete", action: .deleteButtonTapped,
        available: { !$0.isBusy }, completion: { $0.isDeleting ? .running : .succeeded })
      .operation("close", label: "Close", action: .closeButtonTapped, available: { !$0.isBusy })

    let row = FeatureDescriptor<Book, Shelf.BookRowAction>("Book")
      .operation("open", label: "Open book", action: .tapped)

    return Shelf.harnessDescriptor
      .operation("add", label: "Add book", action: .addButtonTapped, available: noSheet)
      .operation("refresh", label: "Refresh", action: .refreshButtonTapped,
        available: { noSheet($0) && !$0.isLoading }, completion: loading)
      .operation("retry", label: "Retry", action: .retryButtonTapped,
        available: { noSheet($0) && $0.loadError != nil && !$0.isLoading }, completion: loading)
      .operation("search", label: "Search", arguments: String.self, action: { .searchQueryChanged($0) },
        available: noSheet, completion: { $0.appliedQuery == $0.searchQuery ? .succeeded : .running })
      .identified("books", state: \.rows, action: \.bookRows, descriptor: row)
      .presentation("addBook", state: \.addBook, action: \.addBook, descriptor: addBook)
      .presentation("detail", state: \.detail, action: \.detail, descriptor: detail)
      .withShelfInvariants()
  }

  /// The URLSession every client uses. In a harness run it goes through the harness network layer,
  /// which replays fixtures, records, injects faults and blocks anything unexpected.
  static func makeSession() -> URLSession {
    #if SHELF_HARNESS_V3
    URLSession(configuration: HarnessNetwork.configure(.ephemeral))
    #else
    URLSession(configuration: .ephemeral)
    #endif
  }

  /// Dependencies for a harness run: seeded uuid, fixed date and random when `TCA_HARNESS_SEED` is set.
  public static func prepare(_ dependencies: inout DependencyValues) {
    #if SHELF_HARNESS_V3
    dependencies.harnessDeterministic()
    #endif
  }
}

extension FeatureDescriptor where State == Shelf.State, Action == Shelf.Action {
  @MainActor
  func withShelfInvariants() -> Self {
    #if SHELF_HARNESS_V3
    self
      .invariant("unread badge matches the list") { $0.unreadCount == $0.books.filter { !$0.isRead }.count }
      .invariant("no duplicate books") { Set($0.books.map(\.id)).count == $0.books.count }
      .invariant("saving means a save is in flight") { $0.addBook?.isSaving != true || $0.savesInFlight > 0 }
    #else
    self
    #endif
  }
}
