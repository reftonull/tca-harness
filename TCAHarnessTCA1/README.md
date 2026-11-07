# Typed TCA harness

The repository root Swift package exposes the `TCAHarnessTCA1` app-facing product and a model-independent `TCAHarness` product. Link the adapter product and `import TCAHarnessTCA1`; it re-exports the shared types used by generated schemas.

The package has three layers: typed feature descriptors, descriptor/schema macros, and a live capability runtime. The earlier reflection-based `DiscoveredHarness` remains an experiment; the [isowords app example](../examples/isowords/README.md) uses `HarnessRuntime` and typed routes.

## Generate ordinary features

```swift
@HarnessSchema
struct RenameInput: Codable {
  var title: String
  var labels: [String]
  var note: String?
}

@HarnessFeature
@Reducer
struct Editor {
  @ObservableState
  struct State {
    var title = ""
    @HarnessIgnore var privateNotes = ""
  }
  enum Action {
    case saveButtonTapped
    @HarnessOperation("Rename document")
    case rename(RenameInput)
    @HarnessIgnore case saveResponse(Result<Void, Error>)
  }
  // Existing reducer body remains responsible for all mutations and effects.
}
```

`Editor.harnessDescriptor` contains typed observation readers and action constructors. Named `ButtonTapped` actions are exposed by convention; other operations opt in with `@HarnessOperation`. Unsupported payloads produce diagnostics. `@HarnessIgnore` excludes a state field or action from generated metadata. Known credential field names are redacted. Nested observations compose child descriptors, preserving child exclusions; opaque leaf values still use bounded `StateInspection`.

Schemas support explicit stored fields, recursively annotated structs, String raw-value enums, primitives, arrays, and nullable values. Input types remain Codable and may provide their own HarnessInput implementation. Struct payloads use their fields directly; scalar/enum/array payloads are wrapped in `{ "value": ... }`. Optional schema fields are required on the wire with `null` representing absence. Schema and typed decoding both run before dispatch.

## Compose typed scopes

```swift
let descriptor = Parent.harnessDescriptor
  .optional("editor", state: \.editor, action: \.editor,
            descriptor: Editor.harnessDescriptor)
```

Adapters cover ordinary children, optional children, presentation wrappers, identified collections, and navigation stacks. Enum destinations/computed scopes use `child(_:state:action:descriptor:)` with typed projection/embedding closures. Macros generate standard adapters from locally declared, explicitly typed State fields and matching Action payload syntax (`Child.Action`, `PresentationAction<Child.Action>`, `IdentifiedActionOf<Child>`, `StackActionOf<Child>`). They do not inspect another macro's expansion or infer arbitrary reducer-body semantics. External and unusual layouts use explicit descriptors, as the isowords example demonstrates.

## Attach to the existing store

```swift
let harness = store.harness(Editor.self)
try harness.startIfEnabled()
```

`@HarnessFeature` generates `HarnessFeatureProvider` conformance and the descriptor used by this overload. Retain the returned `StoreHarness` alongside your store. It owns the runtime/server and uses that exact store for observation and dispatch; no extra store or read/send closures are required.

For an explicit descriptor, use `store.harness(descriptor: descriptor, verify: { state, condition in ... })`. Lower-level `HarnessRuntime` remains available for custom transports.

## Run headless

The same descriptors and the same `tca` CLI work with or without a UI. A small executable can host your real reducers with no app, window or simulator, and agents and tests drive it through the same operations they use against the app. There is no rendering or animation to wait for, which keeps agent loops and behavior tests fast.

```swift
@main struct Host {
  static func main() async throws {
    let store = Store(initialState: Feature.State()) { Feature().harnessTimeline() } withDependencies: { ... }
    try await store.harness(Feature.self).runHeadless(port: 8790)
  }
}
```

`runHeadless(port:)` starts the loopback listener, prints `TCA harness listening on 127.0.0.1:<port>` to standard error once it accepts connections, and suspends until `stop()` is called or the calling task is cancelled. Calling it is the opt-in, so `TCA_HARNESS` is not consulted. The `.shared` timeline still records only with `TCA_HARNESS=1`; to record without that, pass `HarnessTimeline(isEnabled: true)` to both `.harnessTimeline(_:)` and `harness(_:timeline:)`. `HarnessServer.run(port:onReady:)` is the transport-level form.

Things a headless host has to do itself:

- **View lifecycle.** Nothing sends the actions your views send (`.task`, `.onAppear`). Send them from the host, for example with a reducer `.onChange(of:)` that sends a child's `.task` when it is presented. Effects started that way are cancelled on dismissal, like SwiftUI's `.task`.
- **Run loop.** `async main` services the main actor but not `RunLoop.main`. If your features schedule timers on `RunLoop.main` (for example a `mainRunLoop` dependency), start `runHeadless` in a `Task` and call `RunLoop.main.run()` instead.
- **Platform.** The host must compile your feature modules. Features that import UIKit can be built for Mac Catalyst (`swift build --triple arm64-apple-ios-macabi`), which runs as a plain macOS process.

**Release builds.** Like `start(port:)`, `runHeadless` exists in every build but throws in builds compiled without `DEBUG`, because the listener is compiled out. The error says how to fix it: build with the debug configuration (`swift build`), or add `-Xswiftc -DDEBUG` to an optimized build. A headless host is a development tool, and this keeps release builds free of the listener. The [isowords headless example](../examples/isowords/README.md#headless) plays a full game this way.

## Record a timeline for devtools

```swift
let store = Store(initialState: AppFeature.State()) {
  AppFeature().harnessTimeline()
}
let harness = store.harness(AppFeature.self)
```

`.harnessTimeline()` records every action reduced by the root reducer, so apply it outermost. Both calls default to `HarnessTimeline.shared`; pass the same custom instance to both to change capacity or detail. Each entry holds the case path and payload, the source (app, effect, or agent with its operation ID), the state snapshot and changed paths, reducer and recorder time, effect status, and the features mounted by the descriptor. `./scripts/tca devtools` reads it through the `timeline` method; `tca doctor` reports whether one is recording.

**Privacy.** The default `.projected` detail snapshots state through the descriptor's observation, the same view agents get: `@HarnessIgnore` fields, explicit projections and credential redaction apply. Payloads keep their structure and case names, but values are replaced by their type (`"<String>"`). `HarnessTimeline(detail: .reflected)` records all reflected state and payload values, minus credential-named fields; use it only when nothing in state or actions should stay out of a local debugging tool.

**Cost.** Inside the reducer the recorder only captures the action, state and previous state (values share storage). Snapshots, diffs and mounts are computed when a page is served, so a timeline nobody watches costs almost nothing. In the isowords example (Debug build) this is about 0.03–0.06 ms per action in the reducer and 5–20 ms per entry when served, mostly the app's own observation function; both are shown in the panel. Because snapshots are deferred, a reference-typed field in state is read when served, not when the action ran.

**Effects.** Each non-`.none` effect is wrapped to observe the actions it sends and when it ends; reducer results and action order are unchanged. An effect-sent action is linked to its cause by matching the action's printed description (case and payload) in send order. Two pending actions that print the same, such as `Data` payloads of equal length, can be confused. Cancellation by an inner `.cancellable(id:)` is reported as `ended`; a Combine-based effect cancelled as a whole (for example through a cancelled `StoreTask`) stays `running`. Detecting `.none` relies on TCA 1's internal effect layout. The recorder is inert unless `TCA_HARNESS=1`, always inert in builds compiled without `DEBUG`, and retains 500 entries. Stores sharing a timeline interleave their entries.

The default launch path stays disabled until `TCA_HARNESS=1` is set. `TCA_HARNESS_PORT` optionally overrides port 8765; malformed enabled ports throw an actionable configuration error. `start(port:)` is available for explicit lifecycle management; `stop()` stops the listener.

**Release builds.** The listener is compiled only when `DEBUG` is defined (the Debug configuration in SwiftPM and Xcode). In other builds the API is unchanged so apps compile either way, but `startIfEnabled()` returns `false` without reading the environment, `start(port:)` throws, and `HarnessTimeline.isEnabled` is always `false`, so `.harnessTimeline()` is a pass-through. `HarnessServer.isAvailable` reports which kind of build you have.

Run the read-only check before adding model credentials:

```
./scripts/tca doctor --port 8765
```

Doctor checks connectivity, protocol version, mounted features, operation identities and runtime diagnostics. Duplicate routes are reported through inspection and fail closed. An empty set of currently available operations is a warning, not a failed connection. Doctor neither dispatches actions nor calls models. `inspect` lists the mounted graph; observations and completion use polling, not subscriptions.

Operations can supply `available`, `validate`, `completion`, and a typed cancellation action. Without a completion predicate, success means synchronous dispatch only. Cancellation invokes the supplied reducer action; the reducer must actually cancel its effect. Child removal cancels the receipt but does not independently manage arbitrary effects. Completion predicates must correlate results to the work they started; the runtime cannot infer request identity from application state.

Lifecycle identity defaults to TCA ObservableState's public underscored `_$id`, an isolated experimental seam. Supply the descriptor's `identity` closure for an application-owned lifetime token. For non-observable state without an identity, removal/recreation between observations cannot be detected. Collection IDs identify routes, while instance identity distinguishes replacement at the same ID. Duplicate feature/operation routes fail closed and appear in `runtime.diagnostics`.

## Validate

```
xcodegen generate --spec prototypes/harness-validation/project.yml
cd prototypes/harness-validation
flowdeck test --config flowdeck.json
```

The macOS validation scheme runs macro expansion/diagnostic snapshots and real TCA store tests for nested arguments, privacy, optional replacement, identified/stack routing, deduplication, completion, cancellation, and duplicate routes. The validation project consumes the root package directly, with its own build directory; no isowords checkout or private TCA 2 dependency is required. The extra macro implementation target compiles the same source as the plugin so its expansions can be tested by MacroTesting.

This is a working implementation, not a guarantee of arbitrary Swift support. Custom CodingKeys, opaque payloads, associated-value enum schemas, view-local navigation, effect correlation, version compatibility, and production transport require explicit work or adapters. Tested with TCA 1.26 on Swift 6.4; the isowords example pins TCA 1.13. Requires iOS 17 / macOS 14 (Observation). On Swift 6.4, TCA itself only compiles from 1.26.0.
