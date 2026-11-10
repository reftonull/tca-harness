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
    let noSheet: (Shelf.State) -> Bool = { !$0.isCovered }
    let loading: (Shelf.State) -> HarnessOperationStatus = { $0.isLoading ? .running : .succeeded }

    let addBook = AddBook.harnessDescriptor
      .operation("setTitle", label: "Set title", arguments: String.self,
        action: { .binding(.set(\.draft.title, $0)) }, available: { !$0.isSaving && !$0.isSaved })
      .operation("setAuthor", label: "Set author", arguments: String.self,
        action: { .binding(.set(\.draft.author, $0)) }, available: { !$0.isSaving && !$0.isSaved })
      .operation("save", label: "Save", action: .saveButtonTapped,
        // Mirrors the button: a spinner while saving, replaced by Done once saved. The double-save bug
        // leaves it tappable while the request is in flight.
        available: { $0.canSubmit && $0.saveError == nil && !$0.isSaved && (!$0.isSaving || bugs.contains(.doubleSave)) },
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

    let discover = Discover.harnessDescriptor
      .operation("search", label: "Search catalog", arguments: String.self, action: { .searchSubmitted($0) },
        completion: { $0.isSearching ? .running : .succeeded })
      .operation("close", label: "Close", action: .closeButtonTapped)

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
      .operation("stats", label: "Reading stats", action: .statsButtonTapped, available: noSheet,
        completion: { $0.stats?.running.isEmpty == false ? .running : .succeeded })
      .operation("goal", label: "Reading goal", action: .goalButtonTapped, available: noSheet,
        completion: { $0.goal?.isLoading == true ? .running : .succeeded })
      .operation("closeGoal", label: "Done", action: .goalDoneButtonTapped, available: { $0.goal?.isSaving == false })
      .operation("discover", label: "Find books", action: .discoverButtonTapped, available: noSheet)
      .identified("books", state: \.rows, action: \.bookRows, descriptor: row)
      .covering("bookRows")  // Mounted as `books`; `tca exposure` would otherwise list the case as unexposed.
      .presentation("addBook", state: \.addBook, action: \.addBook, descriptor: addBook)
      .presentation("detail", state: \.detail, action: \.detail, descriptor: detail)
      .presentation("discover", state: \.discover, action: \.discover, descriptor: discover)
      // Vanilla SwiftUI screens. Stats is wrapped in TCA: its operations become `perform` actions.
      // Close dismisses through the store, like a TCA child's.
      .presentation("stats", state: \.stats, action: \.stats,
        descriptor: Hosted.descriptor(StatsModel.harnessDescriptor).operation("close", label: "Close", action: .dismiss))
      // Goal is mounted directly: its operations call the model.
      .model("goal", { $0.goal }, descriptor: GoalModel.harnessDescriptor)
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

  /// Conditions `tca run --verify` checks against state, so the app (not the model) decides when a goal
  /// is done: `onShelf:TITLE` (a book with that title is on the shelf) and `allRead`. `nil` for
  /// conditions it doesn't know.
  public static func verify(_ state: Shelf.State, _ condition: String) -> Bool? {
    if condition.hasPrefix("onShelf:") {
      let title = condition.dropFirst("onShelf:".count).lowercased()
      return state.books.contains { $0.title.lowercased() == title }
    }
    if condition == "allRead" { return !state.books.isEmpty && state.books.allSatisfy(\.isRead) }
    return nil
  }

  /// Dependencies for a harness run: seeded uuid, fixed date and random when `TCA_HARNESS_SEED` is set.
  public static func prepare(_ dependencies: inout DependencyValues) {
    #if SHELF_HARNESS_V3
    dependencies.harnessDeterministic()
    #endif
  }
}

// The vanilla models' descriptors: what a team adds next to an `@Observable` model, with no TCA.
extension StatsModel {
  @MainActor
  public static var harnessDescriptor: ModelDescriptor<StatsModel> {
    .model("Stats")
      // Mirrors the toolbar button, disabled while loading.
      .operation("refresh", label: "Refresh", available: { !$0.isLoading }) { await $0.load() }
      .operation("retry", label: "Retry", available: { $0.error != nil && !$0.isLoading }) { await $0.load() }
      .invariant("read and unread add up to the total") { model in
        model.summary.map { $0.read + $0.unread == $0.total } ?? true
      }
  }
}

extension GoalModel {
  @MainActor
  public static var harnessDescriptor: ModelDescriptor<GoalModel> {
    .model("Goal")
      .operation("setGoal", label: "Set goal", arguments: Int.self, available: { !$0.isLoading && !$0.isSaving },
        validate: { _, value in
          guard (1...1000).contains(value) else { throw HarnessArgumentError("A goal is 1 to 1000 books") }
        }) { $0.setDraft($1) }
      .operation("save", label: "Save goal", available: { $0.canSave }) { await $0.save() }
      .operation("retry", label: "Retry", available: { $0.error != nil && $0.yearly == 0 && !$0.isLoading }) {
        await $0.load()
      }
      .invariant("progress matches the goal") { $0.progressPercent == GoalModel.percent(read: $0.booksRead, of: $0.yearly) }
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
      // "Results for …" must name what's in the search field once nothing is loading.
      .invariant("catalog results are for the search field") { state in
        state.discover.map { $0.isSearching || $0.error != nil || $0.resultsFor == $0.query } ?? true
      }
    #else
    self
    #endif
  }
}
