import ComposableArchitecture
import SwiftUI
import Foundation
import TCAHarnessTCA2
import Testing

// Mirrors the photography app's feature tree (PhotographyKit, feat/camera-import-flow) without
// SQLiteData. Harness annotations are what that app would add; everything else keeps its shape:
// `@Fetch`-style wrappers, `let` IDs, static constants, `Scope` without an action path,
// `@Feature enum` destinations, a destination reused across features, and UUID-payload taps.

/// Stands in for SQLiteData's `@Fetch` (TCA treats wrappers named Fetch as observation-ignored): a wrapper over reference storage.
@propertyWrapper
struct Fetch<Value> {
  final class Box { var value: Value; init(_ value: Value) { self.value = value } }
  private let box: Box
  init(wrappedValue: Value) { box = Box(wrappedValue) }
  var wrappedValue: Value {
    get { box.value }
    nonmutating set { box.value = newValue }
  }
}

struct ProjectSummary: Equatable, Identifiable {
  let id: UUID
  var name: String
}

@HarnessFeature
@Feature struct PhotoRoot {
  struct State {
    var cameras = Cameras.State()
    var projects = Projects.State()
    @Fetch var assetIdentifiers: [String] = ["asset-1"]
  }
  enum Action {
    case cameras(Cameras.Action)
    case projects(Projects.Action)
  }
  var body: some Feature {
    Scope(\.cameras) { Cameras() }
    Scope(\.projects) { Projects() }
  }
}

@HarnessFeature
@Feature struct Projects {
  @HarnessFeature
  @Feature enum Destination {
    case detail(ProjectDetail)
    case newProject(NewProject)
  }
  struct State {
    var destination: Destination.State?
    @Fetch var projects: [ProjectSummary] = []
    var projectChoices: [HarnessChoice<UUID>] { projects.map { HarnessChoice($0.id, label: $0.name) } }
  }
  enum Action {
    @HarnessOperation("Delete project", choices: \State.projectChoices)
    case deleteProjectButtonTapped(UUID)
    case destination(Destination.Action)
    case newProjectButtonTapped
    @HarnessOperation("Open project", choices: \State.projectChoices)
    case projectTapped(UUID)
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .deleteProjectButtonTapped(let id):
        state.projects.removeAll { $0.id == id }
      case .destination(.newProject(.cancelButtonTapped)):
        state.destination = nil
      case .destination(.newProject(.createButtonTapped)):
        guard case .newProject(let newProject) = state.destination, !newProject.trimmedName.isEmpty else { return }
        let project = ProjectSummary(id: UUID(), name: newProject.trimmedName)
        state.projects.append(project)
        state.destination = .detail(ProjectDetail.State(projectID: project.id))
      case .destination:
        break
      case .newProjectButtonTapped:
        state.destination = .newProject(NewProject.State())
      case .projectTapped(let id):
        state.destination = .detail(ProjectDetail.State(projectID: id))
      }
    }
    .ifLet(\.destination) { Destination.body }
  }
}

@HarnessFeature(dismiss: "Close the new project")
@Feature struct NewProject {
  struct State {
    @HarnessBinding("Name the new project") var name = ""
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canCreate: Bool { !trimmedName.isEmpty }
  }
  enum Action {
    case cancelButtonTapped
    @HarnessOperation("Create the project", available: \State.canCreate)
    case createButtonTapped
  }
}

@HarnessFeature
@Feature struct ProjectDetail {
  struct State {
    let projectID: UUID
    @Fetch var project: ProjectSummary? = nil
    var isPickingPhotographs = false
    var photo: PhotoViewer.State?
  }
  enum Action {
    case addPhotographsButtonTapped
    case photo(PhotoViewer.Action)
    @HarnessOperation("Open a photograph")
    case photographTapped(UUID)
    @HarnessIgnore case photographsPicked([String])
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .addPhotographsButtonTapped:
        store.addTask {
          try await Task.sleep(for: .milliseconds(50))  // Authorization prompt.
          try store.modify { $0.isPickingPhotographs = true }
        }
      case .photo, .photographsPicked:
        break
      case .photographTapped(let id):
        state.photo = PhotoViewer.State(photographID: id, projectID: state.projectID)
      }
    }
    .ifLet(\.photo) { PhotoViewer() }
  }
}

@HarnessFeature
@Feature struct PhotoViewer {
  struct State {
    var photographID: UUID
    let projectID: UUID
  }
  enum Action {
    @HarnessOperation("Close the viewer", completion: .dispatch)
    case closeButtonTapped
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .closeButtonTapped:
        store.addTask { try store.dismiss() }
      }
    }
  }
}

@HarnessFeature
@Feature struct Cameras {
  @HarnessFeature
  @Feature enum Destination {
    case session(ImportSession)
  }
  struct State {
    var destination: Destination.State?
    var newPhotoCount: Int?
  }
  enum Action {
    case destination(Destination.Action)
    case iPhoneCardTapped
    @HarnessIgnore case viewAppeared
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .destination, .viewAppeared: break
      case .iPhoneCardTapped: state.destination = .session(ImportSession.State())
      }
    }
    .ifLet(\.destination) { Destination.body }
  }
}

@HarnessFeature
@Feature struct ImportSession {
  static let photoLimit = 2_000
  @HarnessFeature
  @Feature enum Destination {
    case newProject(NewProject)
  }
  struct State {
    var destination: Destination.State?
    var filed: [UUID: Set<String>] = [:]
    var selection: Set<String> = []
    var photos: [String] = ["a", "b"]
    var photoChoices: [HarnessChoice<String>] { photos.map { HarnessChoice($0, label: "Photo \($0)") } }
  }
  enum Action {
    case closeButtonTapped
    case destination(Destination.Action)
    case newBoxTapped
    @HarnessOperation("Toggle a photo", choices: \State.photoChoices)
    case photoTapped(String)
  }
  var body: some Feature {
    Update { state, action in
      switch action {
      case .closeButtonTapped: store.addTask { try store.dismiss() }
      case .destination(.newProject(.cancelButtonTapped)): state.destination = nil
      case .destination: break
      case .newBoxTapped: state.destination = .newProject(NewProject.State())
      case .photoTapped(let id):
        if state.selection.remove(id) == nil { state.selection.insert(id) }
      }
    }
    .ifLet(\.destination) { Destination.body }
  }
}

@MainActor
@Suite struct PhotographyShapeTests {
  @Test func newProjectFlowThroughBindingsAndDestinations() async throws {
    let store = Store(initialState: PhotoRoot.State()) { PhotoRoot() }
    let harness = store.harness(PhotoRoot.self)
    let client = Client(harness.runtime)
    await client.observe()
    #expect(client.state["assetIdentifiers"] as? [String] == ["asset-1"])  // wrapper unwrapped
    #expect(client.candidate("root/projects/destination/newProject/createButtonTapped") == nil)

    await client.dispatch("root/projects/newProjectButtonTapped")
    #expect(client.candidate("root/projects/destination/newProject/createButtonTapped") == nil)  // name is empty
    #expect(await client.dispatch("root/projects/destination/newProject/name", ["value": "Coast walk"])["ok"] as? Bool == true)
    #expect(await client.dispatch("root/projects/destination/newProject/createButtonTapped")["ok"] as? Bool == true)
    #expect(store.projects.projects.map(\.name) == ["Coast walk"])
    let projects = client.state["projects"] as? [String: Any]
    #expect((projects?["destination"] as? [String: Any])?["case"] as? String == "detail")

    let pick = await client.dispatch("root/projects/destination/detail/addPhotographsButtonTapped")
    #expect(status(pick) == "running")
    #expect(status(await client.wait(pick)) == "succeeded")

    let photo = UUID()
    await client.dispatch("root/projects/destination/detail/photographTapped", ["value": photo.uuidString])
    let close = await client.dispatch("root/projects/destination/detail/photo/closeButtonTapped")
    #expect(status(close) == "succeeded")
    try await Task.sleep(for: .milliseconds(50))
    await client.observe()
    #expect(client.candidate("root/projects/destination/detail/photo/closeButtonTapped") == nil)

    let id = store.projects.projects[0].id
    #expect(client.candidate("root/projects/projectTapped/\(id.uuidString)") != nil)
    #expect(await client.dispatch("root/projects/deleteProjectButtonTapped/\(id.uuidString)")["ok"] as? Bool == true)
    #expect(store.projects.projects.isEmpty)
  }

  @Test func importSessionReusesNewProjectDestination() async throws {
    let store = Store(initialState: PhotoRoot.State()) { PhotoRoot() }
    let harness = store.harness(PhotoRoot.self)
    let client = Client(harness.runtime)
    await client.dispatch("root/cameras/iPhoneCardTapped")
    await client.dispatch("root/cameras/destination/session/photoTapped/b")
    await client.dispatch("root/cameras/destination/session/newBoxTapped")
    #expect(client.candidate("root/cameras/destination/session/destination/newProject/cancelButtonTapped") != nil)
    let inspection = await client.call(["method": "inspect", "path": "root/cameras"])
    let paths = (inspection["features"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
    #expect(paths == ["root/cameras", "root/cameras/destination", "root/cameras/destination/session",
      "root/cameras/destination/session/destination", "root/cameras/destination/session/destination/newProject"])
    // Closing the session from an effect is marked neither way here, so the default `.effects`
    // completion reports the dismissal as cancelled: the feature is gone when its task ends.
    let close = await client.dispatch("root/cameras/destination/session/closeButtonTapped")
    #expect(status(await client.wait(close)) == "cancelled")
    #expect(store.cameras.destination == nil)
  }

  @Test(.enabled(if: HarnessServer.isAvailable, "Timelines record only in DEBUG builds"))
  func timelineRecordsActionsAndAgentBindings() async throws {
    let timeline = HarnessTimeline(isEnabled: true)
    let store = Store(initialState: PhotoRoot.State()) { PhotoRoot().harnessTimeline(timeline) }
    let harness = store.harness(PhotoRoot.self, timeline: timeline)
    let client = Client(harness.runtime)
    store.send(.cameras(.iPhoneCardTapped))  // From the app, not the agent.
    // A write between actions, like a view's binding, belongs to no action.
    Bindable(store).cameras.newPhotoCount.wrappedValue = 3
    await client.dispatch("root/projects/newProjectButtonTapped")
    await client.dispatch("root/projects/destination/newProject/name", ["value": "Coast walk"])
    try await Task.sleep(for: .milliseconds(10))  // Mounts are read once the store settles.
    await client.dispatch("root/projects/destination/newProject/dismiss")

    let page = await client.call(["method": "timeline", "since": 0])
    let entries = (page["timeline"] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
    #expect(entries.map { $0["action"] as? [String] ?? [] } == [
      ["cameras", "iPhoneCardTapped"],
      ["projects", "newProjectButtonTapped"],
      ["binding", "projects", "destination", "newProject", "name"],
      ["dismiss", "projects", "destination", "newProject"],
    ])
    #expect(entries.map { $0["source"] as? String } == ["app", "agent", "agent", "agent"])
    #expect(entries[1]["changes"] as? [String] == ["projects.destination"])
    #expect((entries[1]["candidateID"] as? String)?.hasPrefix("root/projects/newProjectButtonTapped@") == true)
    #expect((entries[1]["changes"] as? [String])?.contains("projects.destination") == true)
    let mounts = (entries[1]["mounts"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
    #expect(mounts.contains("root/projects/destination/newProject"))
  }

  @Test func presentedFeaturesOfferOneDismissal() async throws {
    let store = Store(initialState: PhotoRoot.State()) { PhotoRoot() }
    let harness = store.harness(PhotoRoot.self)
    let client = Client(harness.runtime)
    await client.observe()
    #expect(client.candidates.filter { $0.contains("/dismiss@") }.isEmpty)

    await client.dispatch("root/projects/newProjectButtonTapped")
    // Only features that opt in can be dismissed; the import session closes through its own actions.
    #expect(client.candidates.filter { $0.contains("/dismiss@") }.map { $0.components(separatedBy: "@")[0] }
      == ["root/projects/destination/newProject/dismiss"])
    #expect(await client.dispatch("root/projects/destination/newProject/dismiss")["ok"] as? Bool == true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(store.projects.destination == nil)
  }
}
