import HarnessMacrosTCA2Plugin
import MacroTesting
import Testing

@Suite(.macros(record: .missing, macros: [
  "HarnessFeature": HarnessFeatureMacro.self, "HarnessSchema": HarnessSchemaMacro.self,
  "HarnessOperation": MarkerMacro.self, "HarnessIgnore": MarkerMacro.self,
  "HarnessBinding": MarkerMacro.self, "HarnessField": MarkerMacro.self, "HarnessObserve": MarkerMacro.self,
]))
struct HarnessMacroTests {
  @Test func structFeatureComposition() {
    assertMacro {
      """
      @HarnessFeature
      @Feature struct Workspace {
        struct State {
          var archive: Spawn<Archive>?
          var counter = Counter.State()
          var destination: Destination.State?
          var items: [Item.State] = []
          var path: [Path.State] = []
          var pages = [Spawn<Page>]()
          var sidebar = Spawn(Sidebar.State())
          @HarnessBinding("Rename") var title: String = ""
          var password = ""
          @HarnessIgnore var notes = ""
          @Fetch var projects: [Project] = []
          @Trigger var refresh
          private var cache = 0
          static let limit = 3
          var canSave: Bool { !title.isEmpty }
          @HarnessObserve var projectCount: Int { projects.count }
        }
        enum Action {
          case counter(Counter.Action)
          case destination(Destination.Action)
          case items(Item.State.ID, Item.Action)
          case path(Path.State.ID, Path.Action)
          case saveButtonTapped
          case rowTapped
          @HarnessOperation("Save draft", available: \\State.canSave, completion: .dispatch)
          case saveDraft
          @HarnessOperation("Add", completion: .effects)
          case add(Draft)
          @HarnessOperation("Open", choices: \\State.projectChoices)
          case projectTapped(Project.ID)
          @HarnessOperation("Rename", choices: \\State.projectChoices)
          case rename(id: Project.ID, title: String)
          @HarnessIgnore case response(Result<Int, Error>)
        }
      }
      """
    } expansion: {
      #"""
      @Feature struct Workspace {
        struct State {
          var archive: Spawn<Archive>?
          var counter = Counter.State()
          var destination: Destination.State?
          var items: [Item.State] = []
          var path: [Path.State] = []
          var pages = [Spawn<Page>]()
          var sidebar = Spawn(Sidebar.State())
          var title: String = ""
          var password = ""
          var notes = ""
          @Fetch var projects: [Project] = []
          @Trigger var refresh
          private var cache = 0
          static let limit = 3
          var canSave: Bool { !title.isEmpty }
          var projectCount: Int { projects.count }
        }
        enum Action {
          case counter(Counter.Action)
          case destination(Destination.Action)
          case items(Item.State.ID, Item.Action)
          case path(Path.State.ID, Path.Action)
          case saveButtonTapped
          case rowTapped
          case saveDraft
          case add(Draft)
          case projectTapped(Project.ID)
          case rename(id: Project.ID, title: String)
          case response(Result<Int, Error>)
        }

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("Workspace", observation: { state in
            .object([
              "archive": state.archive.map {
                        Archive.harnessDescriptor.snapshot($0.state)
                      } ?? .null,
              "counter": Counter.harnessDescriptor.snapshot(state.counter),
              "destination": state.destination.map {
                        Destination.harnessDescriptor.snapshot($0)
                      } ?? .null,
              "items": .array(state.items.prefix(60).map {
                          Item.harnessDescriptor.snapshot($0)
                        }),
              "path": .array(state.path.prefix(60).map {
                          Path.harnessDescriptor.snapshot($0)
                        }),
              "pages": .array(state.pages.prefix(60).map {
                          Page.harnessDescriptor.snapshot($0.state)
                        }),
              "sidebar": Sidebar.harnessDescriptor.snapshot(state.sidebar.state),
              "title": StateInspection.snapshot(state.title as Any),
              "password": .string("<redacted>"),
              "projects": StateInspection.snapshot(state.projects as Any),
              "projectCount": StateInspection.snapshot(state.projectCount as Any)
            ])
            })
          .child("archive", descriptor: Archive.harnessDescriptor) {
            $0.spawn(\.archive)
          }
          .child("counter", descriptor: Counter.harnessDescriptor) {
            $0.scope(\.counter)
          }
          .child("destination", descriptor: Destination.harnessDescriptor) {
            $0.scope(\.destination)
          }
          .children("items", descriptor: Item.harnessDescriptor) {
            $0.scope(\.items)
          }
          .children("path", descriptor: Path.harnessDescriptor) {
            $0.scope(\.path)
          }
          .children("pages", descriptor: Page.harnessDescriptor) {
            $0.spawn(\.pages)
          }
          .child("sidebar", descriptor: Sidebar.harnessDescriptor) {
            $0.spawn(\.sidebar)
          }
          .binding("title", label: "Rename", \.title)
          .operation("saveButtonTapped", label: "saveButtonTapped", action: .saveButtonTapped)
          .operation("rowTapped", label: "rowTapped", action: .rowTapped)
          .operation("saveDraft", label: "Save draft", action: .saveDraft, available: {
              $0 [keyPath: \State.canSave]
            }, completion: .dispatch)
          .operation("add", label: "Add", arguments: Draft.self, action: {
              .add($0)
            }, completion: .effects)
          .operation("projectTapped", label: "Open", choices: {
              $0 [keyPath: \State.projectChoices]
            }, action: {
              .projectTapped($0)
            })
          .operation("rename", label: "Rename", choices: {
              $0 [keyPath: \State.projectChoices]
            }, arguments: String.self, action: {
              .rename(id: $0, title: $1)
            })
        }
      }

      extension Workspace: HarnessFeatureProvider {
      }
      """#
    }
  }

  @Test func enumFeatureDestination() {
    assertMacro {
      """
      @HarnessFeature
      @Feature enum Destination {
        case detail(ProjectDetail)
        case newProject(NewProject)
        case sheet(Spawn<Sheet>)
        @FeatureIgnored case message(String)
        case pair(Int, Int)
      }
      """
    } expansion: {
      #"""
      @Feature enum Destination {
        case detail(ProjectDetail)
        case newProject(NewProject)
        case sheet(Spawn<Sheet>)
        @FeatureIgnored case message(String)
        case pair(Int, Int)

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("Destination", observation: { state in
            if case let .detail(value) = state {
                return .object(["case": .string("detail"), "value": ProjectDetail.harnessDescriptor.snapshot(value)])
              }
            if case let .newProject(value) = state {
                return .object(["case": .string("newProject"), "value": NewProject.harnessDescriptor.snapshot(value)])
              }
            if case let .sheet(value) = state {
                return .object(["case": .string("sheet"), "value": Sheet.harnessDescriptor.snapshot(value.state)])
              }
            return StateInspection.snapshot(state)
            })
          .child("detail", descriptor: ProjectDetail.harnessDescriptor) {
            $0.scope(\.detail)
          }
          .child("newProject", descriptor: NewProject.harnessDescriptor) {
            $0.scope(\.newProject)
          }
          .child("sheet", descriptor: Sheet.harnessDescriptor) {
            $0.spawn(\.sheet)
          }
        }
      }

      extension Destination: HarnessFeatureProvider {
      }
      """#
    }
  }

  @Test func structFeatureWithEnumStateAndPrompt() {
    assertMacro {
      """
      @HarnessFeature
      @Feature struct App {
        enum State {
          case loggedIn(LoggedIn.State)
          case loggedOut(LoggedOut.State)
        }
        enum Action {
          case loggedIn(LoggedIn.Action)
          case loggedOut(LoggedOut.Action)
        }
      }

      @HarnessFeature
      @Feature struct SaveAlert: Prompt {
        enum Action {
          case abandonTapped
          case saveTapped
        }
      }
      """
    } expansion: {
      #"""
      @Feature struct App {
        enum State {
          case loggedIn(LoggedIn.State)
          case loggedOut(LoggedOut.State)
        }
        enum Action {
          case loggedIn(LoggedIn.Action)
          case loggedOut(LoggedOut.Action)
        }

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("App", observation: {
              StateInspection.snapshot($0)
            })
          .child("loggedIn", descriptor: LoggedIn.harnessDescriptor) {
            $0.scope(\.loggedIn)
          }
          .child("loggedOut", descriptor: LoggedOut.harnessDescriptor) {
            $0.scope(\.loggedOut)
          }
        }
      }
      @Feature struct SaveAlert: Prompt {
        enum Action {
          case abandonTapped
          case saveTapped
        }

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("SaveAlert", observation: { _ in
              .object([:])
            })
          .operation("abandonTapped", label: "abandonTapped", action: .abandonTapped)
          .operation("saveTapped", label: "saveTapped", action: .saveTapped)
        }
      }

      extension App: HarnessFeatureProvider {
      }

      extension SaveAlert: HarnessFeatureProvider {
      }
      """#
    }
  }

  @Test func schemaWithFieldConstraints() {
    assertMacro {
      """
      @HarnessSchema
      struct Draft: Codable {
        @HarnessField("Task title", minLength: 1, maxLength: 120) var title: String
        var priority: Priority
        var tags: [String]
        var note: String?
        static var empty: Draft { Draft(title: "", priority: .normal, tags: [], note: nil) }
      }

      @HarnessSchema
      enum Priority: String, Codable {
        case low
        case high = "urgent"
      }
      """
    } expansion: {
      """
      struct Draft: Codable {
        var title: String
        var priority: Priority
        var tags: [String]
        var note: String?
        static var empty: Draft { Draft(title: "", priority: .normal, tags: [], note: nil) }

        public static var harnessSchema: HarnessJSONSchema {
          .object([
              "title": .string(description: "Task title", minLength: 1, maxLength: 120),
              "priority": (Priority).harnessSchema,
              "tags": ([String]).harnessSchema,
              "note": (String?).harnessSchema
            ])
        }
      }
      enum Priority: String, Codable {
        case low
        case high = "urgent"

        public static var harnessSchema: HarnessJSONSchema {
          .string(choices: ["low", "urgent"])
        }
      }

      extension Draft: HarnessInput {
      }

      extension Priority: HarnessInput {
      }
      """
    }
  }

  @Test func diagnostics() {
    assertMacro {
      """
      @HarnessFeature
      @Feature struct Broken {
        struct State {
          @HarnessBinding let id: Int
        }
        enum Action {
          case viewAppeared
          case selected(Int)
          case pair(Int, String)
          @HarnessOperation case move(Int, Int)
          @HarnessOperation(choices: \\State.items) case refresh
        }
      }

      @HarnessSchema
      struct Input: Codable {
        @HarnessField("Count") var count: Int
        var untyped = 1
      }

      @HarnessSchema
      enum Mode: Codable { case a }
      """
    } diagnostics: {
      #"""
      @HarnessFeature
      @Feature struct Broken {
        struct State {
          @HarnessBinding let id: Int
          ┬──────────────
          ╰─ 🛑 @HarnessBinding requires a non-private 'var'
        }
        enum Action {
          case viewAppeared
               ┬───────────
               ╰─ ⚠️ Action 'viewAppeared' is not exposed; add @HarnessOperation or @HarnessIgnore to declare intent
          case selected(Int)
               ┬────────────
               ╰─ ⚠️ Action 'selected' is not exposed; add @HarnessOperation with a HarnessInput payload, @HarnessIgnore, or compose an explicit descriptor
          case pair(Int, String)
               ┬────────────────
               ╰─ ⚠️ Action 'pair' is not exposed; add @HarnessOperation with a HarnessInput payload, @HarnessIgnore, or compose an explicit descriptor
          @HarnessOperation case move(Int, Int)
                                 ┬─────────────
                                 ╰─ 🛑 Action 'move' has multiple payloads; wrap them in a @HarnessSchema struct, choose the first with 'choices:', or add @HarnessIgnore
          @HarnessOperation(choices: \State.items) case refresh
                                                        ┬──────
                                                        ╰─ 🛑 @HarnessOperation(choices:) requires the chosen value as the first payload
        }
      }

      @HarnessSchema
      struct Input: Codable {
        @HarnessField("Count") var count: Int
        ┬─────────────────────
        ╰─ 🛑 @HarnessField applies to String fields
        var untyped = 1
            ┬──────────
            ╰─ 🛑 Schema fields require an explicit type
      }

      @HarnessSchema
      ╰─ 🛑 @HarnessSchema enum requires String raw values
      enum Mode: Codable { case a }
      """#
    }
  }

  @Test func dismissibleFeature() {
    assertMacro {
      """
      @HarnessFeature(dismiss: "Close the project")
      @Feature struct Detail {
        struct State {
          var name = ""
        }
        enum Action {
          case shareButtonTapped
        }
      }
      """
    } expansion: {
      """
      @Feature struct Detail {
        struct State {
          var name = ""
        }
        enum Action {
          case shareButtonTapped
        }

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("Detail", observation: { state in
            .object([
              "name": StateInspection.snapshot(state.name as Any)
            ])
            })
          .operation("shareButtonTapped", label: "shareButtonTapped", action: .shareButtonTapped)
          .dismissible("Close the project")
        }
      }

      extension Detail: HarnessFeatureProvider {
      }
      """
    }
  }
}
