import Foundation
import Observation

/// "Reading goal": a small settings-like screen as a plain `@Observable` model. It loads the yearly
/// goal (`GET /goal`), lets the user edit it, and saves it (`PUT /goal`).
///
/// The shelf keeps it by reference and mounts it with `.model("goal", ...)`, the lighter option: the
/// harness calls its methods directly, without the store. Its descriptor (operations and the
/// "progress matches the goal" invariant) is in `ShelfHarness.swift`.
@MainActor @Observable
public final class GoalModel {
  /// The saved goal, in books per year.
  public private(set) var yearly = 0
  /// What the stepper shows; saved with `save()`.
  public var draft = 0
  public private(set) var booksRead = 0
  /// Cached for the progress ring and the "n% of your goal" label.
  public private(set) var progressPercent = 0
  /// The screen opens with a spinner until the first `load()` answers.
  public private(set) var isLoading = true
  public private(set) var isSaving = false
  public private(set) var error: String?
  public private(set) var didSave = false

  private let api: ReadingAPI

  nonisolated public init(api: ReadingAPI = .live) { self.api = api }

  public var canSave: Bool { !isLoading && !isSaving && draft > 0 && draft != yearly }

  public nonisolated static func percent(read: Int, of goal: Int) -> Int {
    goal > 0 ? min(100, read * 100 / goal) : 0
  }

  public func load() async {
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let goal = try await api.fetchGoal()
      yearly = goal.yearly
      draft = goal.yearly
      booksRead = goal.read
      progressPercent = Self.percent(read: booksRead, of: yearly)
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func setDraft(_ value: Int) {
    draft = value
    didSave = false
  }

  public func save() async {
    guard canSave else { return }
    isSaving = true
    error = nil
    didSave = false
    defer { isSaving = false }
    do {
      // The server echoes the goal; we keep the value we sent, like the shelf does with books.
      _ = try await api.saveGoal(draft)
      yearly = draft
      // With `goal-drift` the cached percentage keeps showing progress toward the old goal.
      if !ShelfBugs.fromEnvironment.contains(.goalDrift) {
        progressPercent = Self.percent(read: booksRead, of: yearly)
      }
      didSave = true
    } catch {
      self.error = error.localizedDescription
    }
  }
}
