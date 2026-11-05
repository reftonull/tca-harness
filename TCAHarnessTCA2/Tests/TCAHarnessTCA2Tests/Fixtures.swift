import ComposableArchitecture
import Foundation
import TCAHarnessTCA2

// Test features covering each composition pattern the generated descriptors support.

@HarnessSchema
enum Priority: String, Codable, CaseIterable {
  case low, normal, high
}

@HarnessSchema
struct ItemDraft: Codable, HarnessValidating {
  @HarnessField("Item title", minLength: 1, maxLength: 40) var title: String
  var priority: Priority
  var tags: [String]
  var note: String?

  func harnessValidate() throws {
    if title.trimmingCharacters(in: .whitespaces).isEmpty { throw HarnessArgumentError("Title must not be blank") }
  }
}

@HarnessFeature
@Feature struct Item {
  struct State: Identifiable {
    let id: Int
    var count = 0
    var title = ""
  }
  enum Action {
    case incrementButtonTapped
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .incrementButtonTapped: state.count += 1
      }
    }
  }
}

@HarnessFeature
@Feature struct Editor {
  struct State {
    @HarnessBinding("Set the editor name") var name = ""
    var isSaving = false
    var saved = false
  }
  enum Action {
    case saveButtonTapped
    @HarnessOperation("Close the editor", completion: .dispatch)
    case closeButtonTapped
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .saveButtonTapped:
        state.isSaving = true
        store.addTask {
          try await Task.sleep(for: .milliseconds(150))
          try store.modify { $0.isSaving = false; $0.saved = true }
        }
      case .closeButtonTapped:
        store.addTask { try store.dismiss() }
      }
    }
  }
}

@HarnessFeature
@Feature struct Archive {
  struct State {
    var saved = false
  }
  enum Action {
    case saveButtonTapped
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .saveButtonTapped:
        store.addTask {
          try await Task.sleep(for: .milliseconds(150))
          try store.modify { $0.saved = true }
        }
      }
    }
  }
}

/// Spawned in an array without `Identifiable` state, which TCA2 allows.
@HarnessFeature
@Feature struct Note {
  struct State {
    var pinned = false
  }
  enum Action {
    case pinButtonTapped
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .pinButtonTapped: state.pinned = true
      }
    }
  }
}

@HarnessFeature
@Feature struct Alert: Prompt {
  enum Action {
    case confirmTapped
  }
}

struct Opaque { var handler: () -> Void = {} }

@HarnessFeature
@Feature struct Workspace {
  @HarnessFeature
  @Feature enum Destination {
    case editor(Editor)
    case alert(Alert)
  }
  @HarnessFeature
  @Feature enum Path {
    case item(Item)
    case editor(Editor)
  }
  struct State {
    var archive: Spawn<Archive>?
    var notes: [Spawn<Note>] = []
    var counter = Item.State(id: 0)
    var destination: Destination.State?
    var items: [Item.State] = [Item.State(id: 1), Item.State(id: 2)]
    var path: [Path.State] = []
    var password = "never-export-this"
    @HarnessIgnore var privateNotes = "also-private"
    @HarnessBinding("Set the workspace title") var title: String = ""
    @HarnessBinding var priority: Priority = .normal
    var drafts: [String] = []
    @StoreTaskID var refresh
    var opaque = Opaque()

    var canOpenArchive: Bool { archive == nil }
    var itemChoices: [HarnessChoice<Int>] { items.map { HarnessChoice($0.id, label: "Item \($0.id)") } }
  }
  enum Action {
    case counter(Item.Action)
    case destination(Destination.Action)
    case items(Item.State.ID, Item.Action)
    case path(Path.State.ID, Path.Action)
    case editButtonTapped
    case alertButtonTapped
    @HarnessOperation("Open the archive", available: \State.canOpenArchive)
    case openArchiveTapped
    case closeArchiveButtonTapped
    case pushItemButtonTapped
    case addNoteButtonTapped
    @HarnessOperation("Add a draft")
    case addDraft(ItemDraft)
    @HarnessOperation("Remove", choices: \State.itemChoices)
    case removeItem(id: Int)
    @HarnessOperation("Rename", choices: \State.itemChoices)
    case renameItem(Int, title: String)
    @HarnessIgnore case refreshResponse
  }
  var body: some Feature {
    Features {
      Scope(\.counter) { Item() }
      Update { state, action in
        switch action {
        case .counter, .destination, .items, .path, .refreshResponse:
          break
        case .editButtonTapped:
          state.destination = .editor(Editor.State())
        case .alertButtonTapped:
          state.destination = .alert(Alert.State())
        case .openArchiveTapped:
          state.archive = Spawn(Archive.State())
        case .closeArchiveButtonTapped:
          state.archive = nil
        case .addNoteButtonTapped:
          state.notes.append(Spawn(Note.State()))
        case .pushItemButtonTapped:
          state.path.append(.item(Item.State(id: 10 + state.path.count)))
        case .addDraft(let draft):
          state.drafts.append(draft.title)
        case .removeItem(let id):
          state.items.removeAll { $0.id == id }
        case .renameItem(let id, let title):
          if let index = state.items.firstIndex(where: { $0.id == id }) { state.items[index].title = title }
        }
      }
    }
    .ifLet(\.archive) { Archive() }
    .forEach(\.notes) { Note() }
    .ifLet(\.destination) { Destination.body }
    .forEach(\.items) { Item() }
    .forEach(\.path, dismissStyle: .stack) { Path.body }
  }
}
