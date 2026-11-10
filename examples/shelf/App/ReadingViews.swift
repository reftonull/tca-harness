import ShelfCore
import SwiftUI

// The two vanilla SwiftUI screens: plain views over `@Observable` models, with no TCA in sight.
// Their first load is started by the shelf when it presents them (so the headless host, which has
// no views, does the same), not by a `.task` here.

extension GoalModel: Identifiable {}

struct StatsView: View {
  let model: StatsModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if let error = model.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("Retry") { Task { await model.load() } }
          }
        }
        if let summary = model.summary {
          Section {
            LabeledContent("Books", value: "\(summary.total)")
            LabeledContent("Read", value: "\(summary.read)")
            LabeledContent("Unread", value: "\(summary.unread)")
          }
          Section("By author") {
            ForEach(summary.byAuthor, id: \.author) { row in
              LabeledContent(row.author, value: "\(row.count)")
            }
          }
        }
      }
      .overlay {
        if model.isLoading && model.summary == nil { ProgressView() }
      }
      .navigationTitle("Reading stats")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
            .disabled(model.isLoading)
        }
      }
    }
  }
}

struct GoalView: View {
  let model: GoalModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if model.isLoading {
          ProgressView()
        } else {
          Section {
            Stepper("\(model.draft) books this year", value: Binding(get: { model.draft }, set: { model.setDraft($0) }),
              in: 1...1000)
            Button("Save goal") { Task { await model.save() } }
              .disabled(!model.canSave)
          }
          Section {
            ProgressView(value: Double(model.progressPercent), total: 100)
            Text("\(model.booksRead) read, \(model.progressPercent)% of your goal of \(model.yearly)")
              .font(.subheadline)
          }
          if model.didSave {
            Label("Goal saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          }
        }
        if let error = model.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            if model.yearly == 0 {
              Button("Retry") { Task { await model.load() } }
            }
          }
        }
      }
      .disabled(model.isSaving)
      .navigationTitle("Reading goal")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.disabled(model.isSaving)
        }
      }
    }
  }
}
