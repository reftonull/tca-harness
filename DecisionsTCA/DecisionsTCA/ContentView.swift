import ComposableArchitecture
import DecisionDomain
import SwiftUI

struct ContentView: View {
  let store: StoreOf<TaskList>
  var harnessStatus: String? = nil

  var body: some View {
    NavigationStack {
      List {
        Section("Tasks") {
          ForEach(store.tasks) { task in
            Button {
              store.send(.completeButtonTapped(task.id))
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 5) {
                  Text(task.title).strikethrough(task.isComplete)
                  if !task.notes.isEmpty || !task.dueDate.isEmpty || task.project == .work || task.priority != .normal {
                    Text("\(task.project.rawValue.capitalized) · \(task.priority.rawValue.capitalized) priority" + (task.dueDate.isEmpty ? "" : " · \(task.dueDate)"))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                  if !task.notes.isEmpty {
                    Text(task.notes).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                  }
                }
              } icon: {
                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
              }
              .foregroundStyle(task.isComplete ? .secondary : .primary)
            }
            .disabled(task.isComplete)
          }
        }
        Section {
          ForEach(store.candidates) { candidate in
            Button(candidate.label) {
              store.send(candidate.action)
            }
          }
          if store.candidates.isEmpty {
            Label("All done", systemImage: "checkmark.seal")
          }
        } header: {
          Text("Available actions")
        } footer: {
          Text("Each choice dispatches the same action as the task above. A classifier can select these IDs directly.")
        }
        if let harnessStatus {
          Section("Agent harness") {
            Text(harnessStatus).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Decisions")
      .safeAreaInset(edge: .bottom) {
        if let archive = store.spawn(\.archive) {
          VStack(spacing: 12) {
            Text("Archive: \(archive.tasks.count) completed tasks")
            Text(archive.status.rawValue.capitalized).foregroundStyle(.secondary)
            HStack {
              Button("Save snapshot") { archive.send(.saveButtonTapped) }
                .disabled(archive.status != .idle)
              Button("Close archive") { store.send(.closeArchiveButtonTapped) }
            }
            Text("Prototype: save runs asynchronously in memory.").font(.caption)
          }
          .padding().frame(maxWidth: .infinity).background(.regularMaterial)
        } else if store.tasks.contains(where: \.isComplete) {
          Button("Open archive") { store.send(.openArchiveButtonTapped) }
            .buttonStyle(.borderedProminent).padding()
        }
      }
      .toolbar {
        Button("Reset") { store.send(.resetButtonTapped) }
      }
    }
  }
}

#Preview {
  ContentView(store: Store(initialState: TaskList.State()) { TaskList() })
}
