import ComposableArchitecture
import DecisionDomain
// Re-exported so the app can drive the returned StoreHarness with only `import DecisionHarness`.
@_exported import TCAHarnessTCA2

/// `@HarnessFeature` on `TaskList` and `Archive` supplies the observation, operations, and the
/// spawned archive child; the app adds only its outcome predicates.
@MainActor
public enum TaskHarness {
  public static func attach(to store: StoreOf<TaskList>) -> StoreHarness<TaskList.State, TaskList.Action> {
    store.harness(TaskList.self, verify: verify)
  }

  public static func verify(_ state: TaskList.State, _ condition: String) -> Bool? {
    let allCompleted = state.tasks.allSatisfy(\.isComplete)
    let currentIDs = state.tasks.filter(\.isComplete).map(\.id)
    let saved = state.archive?.status == .saved && state.archive?.tasks.map(\.id) == currentIDs
    switch condition {
    case "allCompleted": return allCompleted
    case "archiveSaved": return saved
    case "allCompletedAndArchived": return allCompleted && saved
    case let condition where condition.hasPrefix("task:"):
      return state.tasks.first { $0.id == String(condition.dropFirst(5)) }?.isComplete == true
    default: return nil
    }
  }
}
