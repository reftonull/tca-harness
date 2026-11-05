// THROWAWAY PROTOTYPE: stdin adapter for the same package embedded in iOS.
import ComposableArchitecture
import DecisionDomain
import DecisionHarness
import Foundation

@main
struct HarnessMain {
  static func main() async {
    let harness = await MainActor.run {
      TaskHarness.attach(to: Store(initialState: TaskList.State()) { TaskList() })
    }
    while let line = await Task.detached(operation: { readLine() }).value {
      var data = await harness.runtime.session.handleJSON(Data(line.utf8))
      data.append(10)
      do { try FileHandle.standardOutput.write(contentsOf: data) }
      catch { break }
    }
  }
}
