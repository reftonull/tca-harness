import ComposableArchitecture
import ShelfCore
import SwiftUI

struct ShelfView: View {
  @Bindable var store: StoreOf<Shelf>
  var onLaunched: () -> Void = {}

  var body: some View {
    NavigationStack {
      List {
        if let error = store.loadError {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
            Button("Retry") { store.send(.retryButtonTapped) }
          }
        }
        ForEach(Array(store.visibleBooks.enumerated()), id: \.offset) { _, book in
          Button {
            store.send(.bookRows(.element(id: book.id, action: .tapped)))
          } label: {
            BookRow(book: book)
          }
          .buttonStyle(.plain)
        }
      }
      .overlay {
        if store.isLoading && store.books.isEmpty {
          ProgressView()
        } else if !store.isLoading && store.visibleBooks.isEmpty && store.loadError == nil {
          ContentUnavailableView("No books", systemImage: "books.vertical")
        }
      }
      .searchable(text: $store.searchQuery.sending(\.searchQueryChanged))
      .refreshable { await store.send(.refreshButtonTapped).finish() }
      .navigationTitle("Shelf")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          HStack(spacing: 6) {
            Text("\(store.unreadCount) unread")
              .font(.subheadline.monospacedDigit())
              .accessibilityIdentifier("unreadBadge")
            if store.hasNewBooks {
              Circle().fill(.blue).frame(width: 8, height: 8)
                .accessibilityLabel("New")
            }
          }
          .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Add book", systemImage: "plus") { store.send(.addButtonTapped) }
        }
        ToolbarItem(placement: .secondaryAction) {
          Button("Reading stats", systemImage: "chart.bar") { store.send(.statsButtonTapped) }
        }
        ToolbarItem(placement: .secondaryAction) {
          Button("Reading goal", systemImage: "target") { store.send(.goalButtonTapped) }
        }
        ToolbarItem(placement: .secondaryAction) {
          Button("Find books", systemImage: "magnifyingglass") { store.send(.discoverButtonTapped) }
        }
      }
      .sheet(item: $store.scope(state: \.addBook, action: \.addBook)) { store in
        AddBookView(store: store)
      }
      .sheet(item: $store.scope(state: \.detail, action: \.detail)) { store in
        BookDetailView(store: store)
      }
      // Vanilla SwiftUI screens. Stats is hosted in the store: the view gets the model, unchanged.
      .sheet(item: $store.scope(state: \.discover, action: \.discover)) { store in
        DiscoverView(store: store)
      }
      .sheet(item: $store.scope(state: \.stats, action: \.stats)) { store in
        StatsView(model: store.model)
      }
      // Goal is held by reference; dismissing tells the store.
      .sheet(item: Binding(get: { store.goal }, set: { if $0 == nil { store.send(.goalDoneButtonTapped) } })) { goal in
        GoalView(model: goal)
      }
    }
    .task {
      await store.send(.task).finish()
      onLaunched()
    }
    // Clears the "new" dot. Redundant unless the `view-only-seen` bug moves that job here alone.
    .onAppear { store.send(.markShelfSeen) }
  }
}

struct BookRow: View {
  let book: Book

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(book.title).font(.headline)
        Text(book.author).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      if book.isRead {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Read")
      }
    }
    .contentShape(Rectangle())
  }
}

struct AddBookView: View {
  @Bindable var store: StoreOf<AddBook>
  private let bugs = ShelfBugs.fromEnvironment

  var body: some View {
    NavigationStack {
      Form {
        TextField("Title", text: $store.draft.title)
        TextField("Author", text: $store.draft.author)
        if store.isSaved {
          Label("Added to your shelf", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
        if let error = store.saveError {
          Section {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("Retry") { store.send(.retryButtonTapped) }
          }
        }
      }
      .disabled(store.isSaving || store.isSaved)
      .navigationTitle("Add book")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if store.isSaved {
            Button("Done") { store.send(.doneButtonTapped) }
          } else {
            Button("Cancel") { store.send(.cancelButtonTapped) }.disabled(store.isSaving)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          // The double-save bug: no spinner in place of Save while the request is in flight.
          if store.isSaving && !bugs.contains(.doubleSave) {
            ProgressView()
          } else if !store.isSaved {
            Button("Save") { store.send(.saveButtonTapped) }
              .disabled(!store.canSubmit || store.saveError != nil)
          }
        }
      }
    }
    .interactiveDismissDisabled(store.isSaving)
  }
}

struct DiscoverView: View {
  @Bindable var store: StoreOf<Discover>
  @State private var text = ""

  var body: some View {
    NavigationStack {
      List {
        if let error = store.error {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        if !store.resultsFor.isEmpty {
          Section("Results for \u{201C}\(store.resultsFor)\u{201D}") {
            ForEach(store.results, id: \.title) { entry in
              VStack(alignment: .leading) {
                Text(entry.title).font(.headline)
                Text(entry.author).font(.subheadline).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .overlay { if store.isSearching { ProgressView() } }
      .searchable(text: $text, prompt: "Title or author")
      .onSubmit(of: .search) { store.send(.searchSubmitted(text)) }
      .navigationTitle("Find books")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { store.send(.closeButtonTapped) }
        }
      }
    }
  }
}

struct BookDetailView: View {
  let store: StoreOf<BookDetail>

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("Author", value: store.book.author)
          LabeledContent("Status", value: store.book.isRead ? "Read" : "Unread")
          LabeledContent("Added", value: store.book.addedAt.formatted(date: .abbreviated, time: .omitted))
        }
        if let error = store.error {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        Section {
          if !store.book.isRead {
            Button("Mark as read") { store.send(.markReadButtonTapped) }
          }
          Button("Delete", role: .destructive) { store.send(.deleteButtonTapped) }
        }
        .disabled(store.isBusy)
      }
      .navigationTitle(store.book.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { store.send(.closeButtonTapped) }.disabled(store.isBusy)
        }
      }
    }
  }
}
