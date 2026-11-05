# TCAHarnessTCA2

Macro-generated harness descriptors for **TCA 2** (the private TCA26 beta, `@Feature`). It is the TCA 2 counterpart of [TCAHarnessTCA1](../TCAHarnessTCA1/README.md) and reuses the shared [TCAHarness](../TCAHarness/README.md) session, schemas, receipts and loopback server unchanged.

This is a separate package (`TCAHarnessTCA2/Package.swift`) because TCA 1.13 and TCA26 cannot resolve in one package graph. It needs GitHub access to `pointfreeco/TCA26`.

## Attach to the existing store

```swift
import TCAHarnessTCA2

let harness = store.harness(Root.self)   // retain alongside the store
try harness.startIfEnabled()             // TCA_HARNESS=1, TCA_HARNESS_PORT optional (default 8765)
```

`store.harness(descriptor:verify:)` attaches an explicit or customized descriptor. `verify` maps condition names to app-defined predicates for `./scripts/tca run --verify`.

## Annotate features

```swift
@HarnessFeature
@Feature struct Projects {
  @HarnessFeature
  @Feature enum Destination {
    case detail(ProjectDetail)
    case newProject(NewProject)
  }
  struct State {
    var destination: Destination.State?
    @FetchAll var projects: [Project] = []
    var projectChoices: [HarnessChoice<Project.ID>] { projects.map { HarnessChoice($0.id, label: $0.name) } }
  }
  enum Action {
    case destination(Destination.Action)
    case newProjectButtonTapped                       // exposed by convention
    @HarnessOperation("Open project", choices: \State.projectChoices)
    case projectTapped(Project.ID)                    // one candidate per project
  }
  // body unchanged
}

@HarnessFeature
@Feature struct NewProject {
  struct State {
    @HarnessBinding("Name the new project") var name = ""
    var canCreate: Bool { !name.isEmpty }
  }
  enum Action {
    case cancelButtonTapped
    @HarnessOperation("Create the project", available: \State.canCreate)
    case createButtonTapped
  }
}
```

| Macro | Purpose |
| --- | --- |
| `@HarnessFeature(dismiss:)` | On a `@Feature struct` or `@Feature enum`; generates `harnessDescriptor` and `HarnessFeatureProvider` conformance. With `dismiss: "Close the project"`, a presented instance also offers `dismiss`, which calls `store.dismiss()` as the back button or a swipe would. Leave it off for features that close only through their own actions, such as a confirmation. |
| `@HarnessOperation(label, available:, choices:, completion:)` | Expose an action. No-payload `…Tapped` cases (including `…ButtonTapped`) are exposed without it. |
| `@HarnessBinding(label, available:)` | Expose a `var` state field as a setter that writes through the store. `Bool` and `String` enum fields get one candidate per other value; other types take a typed `value`. |
| `@HarnessIgnore` | Exclude a state field or action. Unannotated actions that aren't exposed produce a warning. |
| `@HarnessObserve` | Include a computed state property in the observation (pair with `@HarnessIgnore` to publish a projection). |
| `@HarnessSchema`, `@HarnessField(description, minLength:, maxLength:)` | Argument schemas for structs and `String` enums. Inputs conforming to `HarnessValidating` are validated after decoding. |

`available:` and `choices:` take key paths with an explicit root (`\State.canCreate`), since macro arguments have no `State` context.

## What the generated descriptor does

Generated code works from the feature's source as written; it cannot see `@Feature`'s expansion, but it names the members that expansion creates and lets the compiler check them.

- **Observation.** Each stored `State` field is read through its accessor (`state.projects`), so property wrappers such as SQLiteData's `@Fetch`/`@FetchAll` are unwrapped. Child features use their own descriptor's snapshot, so a child's `@HarnessIgnore` and redaction still apply. Other values use bounded reflection (`StateInspection`): `Spawn`, optionals and `StoreTaskID` (`{isRunning}`) are unwrapped, `@Trigger` fields are skipped, reference types are opaque, credential-like field names are redacted. Conform other containers to `HarnessInspectable`.
- **Children** are reached through the live store, the same way a view does:

  | State shape | Mounted with |
  | --- | --- |
  | `var child: Child.State` + `case child(Child.Action)` (`Scope`) | `store.scope(\.child)` |
  | `var child: Child.State?` + `case child(Child.Action)` (`ifLet`) | `store.scope(\.child)` |
  | `var destination: Destination.State?` with a `@Feature enum Destination` | `store.scope(\.destination)`, then `scope(\.case)` per case |
  | `var items: [Item.State]` + `case items(Item.State.ID, Item.Action)` (`forEach`) | `store.scope(\.items)`, at `items/<id>` |
  | `var path: [Path.State]` + `case path(Path.State.ID, Path.Action)` (stack) | `store.scope(\.path)`, at `path/<index>` (stack IDs are opaque) |
  | `Spawn<Child>`, `Spawn<Child>?`, `[Spawn<Child>]`, or `= Spawn(Child.State())` | `store.spawn(\.child)` |

  The pairing rule (a state field with a same-named action case) is the one `@Feature` uses to generate `Scopes`. Spawned children receive their actions directly, as in TCA 2.
- **Identity.** Each mounted feature is leased to its child store's core. A re-presented or re-spawned child is a new core, so it gets a new instance ID and candidates for the old one fail with `unavailable_candidate`.
- **Bindings** write with `Bindable(store)[dynamicMember: keyPath]`, the same public path as `$store.name`. No action is sent; `onChange` observers run as for a SwiftUI binding.
- **Effects and receipts.** `Store.send` returns the task for the work an action started (`store.addTask`, triggered `onChange`/`onMount(id:)`). With the default `completion: .effects`, the receipt stays `running` until that task finishes, then reports `succeeded`, or `cancelled` if the feature was dismounted first. `cancel` cancels that task. Actions that start no tasks succeed immediately. Use `completion: .dispatch` for long-lived effects (timers, streams) and for actions whose effect dismisses their own feature.
- **Customization.** `available(_:_:)`, `completion(_:_:status:)`, `removing(_:)` and `observing(_:)` adjust a generated descriptor by operation ID, and `operation`/`binding`/`child`/`children` add to it. Unknown IDs and duplicates are reported as runtime diagnostics and fail closed.

Candidate IDs are `<feature path>/<operation>[/<choice>]@<instance>`, for example `root/projects/destination/newProject/name@…`.

## Watch it in devtools

```swift
let store = Store(initialState: Root.State()) { Root().harnessTimeline() }   // inert unless TCA_HARNESS=1
let harness = store.harness(Root.self)
```

`./scripts/tca devtools --port <port>` then shows every action the root feature receives, from the app or the agent, with state, diffs and the operations mounted after it. It differs from TCA 1 in three ways:

- **Actions are recorded at the root.** The wrapper reads state on either side of the root feature, so a child's action appears once with the root state it produced.
- **Agent bindings appear as `binding.<path>` entries.** A binding writes state without an action, so the runtime records the write itself, attributed to the agent's operation. Bindings changed by the app's own views aren't recorded.
- **No effect lifecycle.** TCA 2 has no per-action effect value to observe, so entries carry no effect status. Mounted operations are read once the store settles after an action, so a burst of actions shares one reading.

## Not supported

- Payload actions are never exposed by convention; they need `@HarnessOperation` with a `HarnessInput` payload (or `choices:`). Two-payload actions are supported only when the first payload is a choice. `UUID` conforms to `HarnessInput`; app ID types such as `Tagged` need their own conformance.
- Generated code doesn't read the feature `body`, so children installed under names that don't follow the field/action pairing, `Scope`s over computed properties, `@FeatureIgnored` cases, and multi-payload enum cases need explicit `child`/`children` calls.
- Effect completion can't tell a self-dismissal from an external dismissal: both end with the feature gone, so `.effects` reports `cancelled` (see `.dispatch` above). An action whose effect never finishes stays `running` until the client's wait times out.
- No events, preferences, triggers, or `@FeatureLocal` state are surfaced.
- The listener is local-only and unauthenticated, so it is compiled only into `DEBUG` builds. Without `DEBUG`, `startIfEnabled()` returns `false`, `start(port:)` throws, and the timeline records nothing.

## Validate

```sh
cd TCAHarnessTCA2
swift test
```

`HarnessMacroTCA2Tests` snapshot the macro expansions and diagnostics. `TCAHarnessTCA2Tests` drive real `Store`s through `HarnessSession.handleJSON` (observe → dispatch → receipt → wait/cancel → verify), including a fixture with the photography app's feature tree (`PhotographyShape.swift`).

The task demo in [DecisionsPackage](../DecisionsPackage) uses these macros; `DecisionHarness/TaskHarness.swift` only adds verification predicates.
