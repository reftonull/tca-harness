import ComposableArchitecture
import DecisionDomain
import XCTest
@testable import DecisionsTCA

@MainActor
final class DecisionsTCATests: XCTestCase {
  func testCandidateDispatchRemovesCompletedTaskFromChoices() {
    let store = Store(initialState: TaskList.State()) { TaskList() }
    let candidate = store.candidates.first { $0.id == "groceries" }!
    store.send(candidate.action)
    XCTAssertTrue(store.tasks.first { $0.id == "groceries" }!.isComplete)
    XCTAssertEqual(store.candidates.map(\.id), ["laundry", "prototype"])
    store.send(.resetButtonTapped)
    XCTAssertEqual(store.candidates.count, 3)
  }

  func testUnknownCandidateDoesNotChangeState() {
    let store = Store(initialState: TaskList.State()) { TaskList() }
    let original = store.tasks
    store.send(.completeButtonTapped("unknown"))
    XCTAssertEqual(store.tasks, original)
  }
}
