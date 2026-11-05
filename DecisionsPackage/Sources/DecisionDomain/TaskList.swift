import ComposableArchitecture
import Foundation
import TCAHarnessTCA2

@HarnessFeature
@Feature public struct TaskList {
  public struct State {
    public var archive: Spawn<Archive>?
    public var nextTaskID = 1
    public var tasks = [
      TaskItem(id: "groceries", title: "Buy groceries"),
      TaskItem(id: "laundry", title: "Do laundry"),
      TaskItem(id: "prototype", title: "Try action classification"),
    ]

    public init() {}

    public var canOpenArchive: Bool { archive == nil && tasks.contains(where: \.isComplete) }
    public var hasArchive: Bool { archive != nil }
    public var incompleteTasks: [HarnessChoice<String>] {
      tasks.filter { !$0.isComplete }.map { HarnessChoice($0.id, label: $0.title) }
    }

    public var candidates: [Candidate] {
      tasks.filter { !$0.isComplete }.map {
        Candidate(id: $0.id, label: "Complete: \($0.title)")
      }
    }
  }

  public enum Action {
    @HarnessOperation("Close the archive, cancelling any pending save", available: \State.hasArchive)
    case closeArchiveButtonTapped
    @HarnessOperation("Complete", choices: \State.incompleteTasks)
    case completeButtonTapped(String)
    @HarnessOperation("Create a NEW task with a title, generated notes, priority, project, and due date. Use only when the goal requests a task that does not exist.")
    case createTaskSubmitted(TaskDraft)
    @HarnessOperation("Edit an existing task: change its title, notes, priority, project, or date; preserve unspecified fields", choices: \State.incompleteTasks)
    case editTaskSubmitted(String, TaskDraft)
    @HarnessOperation("Open a new archive snapshot containing currently completed tasks", available: \State.canOpenArchive)
    case openArchiveButtonTapped
    @HarnessOperation("Reset all tasks and close the archive")
    case resetButtonTapped
  }

  public struct TaskItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var isComplete = false
    public var title: String
    public var notes = ""
    public var priority: Priority = .normal
    public var project: Project = .personal
    public var dueDate = ""

    public init(id: String, title: String) {
      self.id = id
      self.title = title
    }
  }

  @HarnessSchema
  public enum Priority: String, Codable, CaseIterable, Sendable { case low, normal, high }
  @HarnessSchema
  public enum Project: String, Codable, CaseIterable, Sendable { case personal, work }

  @HarnessSchema
  public struct TaskDraft: Codable, Equatable, Sendable, HarnessValidating {
    @HarnessField("Task title. Preserve an explicitly requested title exactly.", minLength: 1, maxLength: 120)
    public var title: String
    @HarnessField("Task notes. Generate requested prose; otherwise preserve existing notes or use empty text.", maxLength: 1000)
    public var notes: String
    public var priority: Priority
    public var project: Project
    @HarnessField("Real YYYY-MM-DD calendar date, or empty when there is no due date.", maxLength: 10)
    public var dueDate: String

    public init(title: String, notes: String = "", priority: Priority = .normal, project: Project = .personal, dueDate: String = "") {
      self.title = title; self.notes = notes; self.priority = priority
      self.project = project; self.dueDate = dueDate
    }

    public var validationError: String? {
      let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, title.unicodeScalars.count <= 120 else { return "Title must contain 1–120 nonblank characters" }
      guard notes.unicodeScalars.count <= 1000 else { return "Notes must be at most 1000 characters" }
      if !dueDate.isEmpty {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        guard dueDate.count == 10, let date = format.date(from: dueDate), format.string(from: date) == dueDate
        else { return "Due date must be a real YYYY-MM-DD date, or empty" }
      }
      return nil
    }

    public func harnessValidate() throws {
      if let validationError { throw HarnessArgumentError(validationError) }
    }

    public func apply(to task: inout TaskItem) {
      task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      task.notes = notes
      task.priority = priority
      task.project = project
      task.dueDate = dueDate
    }
  }

  public struct Candidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public var action: Action { .completeButtonTapped(id) }
  }

  public init() {}

  public var body: some Feature {
    Update { state, action in
      switch action {
      case .closeArchiveButtonTapped:
        state.archive = nil
      case let .completeButtonTapped(id):
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[index].isComplete = true
      case let .createTaskSubmitted(draft):
        guard draft.validationError == nil else { return }
        var task = TaskItem(id: "new-\(state.nextTaskID)", title: draft.title)
        draft.apply(to: &task)
        state.nextTaskID += 1
        state.tasks.append(task)
      case let .editTaskSubmitted(id, draft):
        guard draft.validationError == nil,
          let index = state.tasks.firstIndex(where: { $0.id == id && !$0.isComplete }) else { return }
        draft.apply(to: &state.tasks[index])
      case .openArchiveButtonTapped:
        guard state.archive == nil, state.tasks.contains(where: \.isComplete) else { return }
        state.archive = Spawn(Archive.State(tasks: state.tasks.filter(\.isComplete)))
      case .resetButtonTapped:
        state = State()
      }
    }
    .ifLet(\.archive) { Archive() }
  }
}

/// A spawned child with a finite asynchronous operation and direct state writes.
/// Saving is deliberately an in-memory simulation; no files or services are mutated.
@HarnessFeature
@Feature public struct Archive {
  public struct State {
    public var status: Status = .idle
    // Agents see which tasks the snapshot holds, not a second copy of every task record.
    @HarnessIgnore public var tasks: [TaskList.TaskItem]
    public init(tasks: [TaskList.TaskItem]) { self.tasks = tasks }
    @HarnessObserve public var taskIDs: [String] { tasks.map(\.id) }
    public var isIdle: Bool { status == .idle }
  }

  public enum Status: String, Codable, Sendable {
    case idle, saving, saved
  }

  public enum Action {
    /// The receipt stays running until the save task finishes, and reports cancellation if
    /// the archive is closed first.
    @HarnessOperation("Save the archive snapshot of completed tasks (asynchronous, in memory)", available: \State.isIdle)
    case saveButtonTapped
  }

  public init() {}

  public var body: some Feature {
    Update { state, action in
      switch action {
      case .saveButtonTapped:
        guard state.status == .idle else { return }
        state.status = .saving
        store.addTask {
          try await Task.sleep(for: .milliseconds(350))
          try store.modify { $0.status = .saved }
        }
      }
    }
  }
}
