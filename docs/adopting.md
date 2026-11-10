# Adopting the harness in a large app

This is a plan for a large TCA app that is mostly server-driven: most screens load something over REST, and some screens are vanilla SwiftUI. It is ordered so that each step pays for itself before the next, and nothing requires writing tests up front. Numbers quoted come from the [Shelf](../examples/shelf/README.md) example.

## What to expect

Integrating an existing app usually needs:

- **Small changes to the app.** The root store gets `.harnessTimeline()` and keeps the attachment. Reducers and views stay as they are.
- **One harness file.** It holds the descriptors for the screens you expose, a few invariants, and the run dependencies: network routing, fixed location and clock, isolated storage.
- **A small headless host**, if you want headless runs: an executable that builds the store, sends what views send on appear, and calls `runHeadless`.
- **Recorded fixtures** for the screens you exercise, plus a `match.json` for what varies between runs.

## Step 1: attach and look around (a day)

Attach the harness to the root store. It does nothing unless launched with `TCA_HARNESS=1`, and the listener is compiled out of release builds.

```swift
let store = Store(initialState: AppFeature.State()) { AppFeature().harnessTimeline() }
let harness = store.harness(AppFeature.self)
try harness.startIfEnabled()
```

Annotate features with `@HarnessFeature`. Actions named `…ButtonTapped` are exposed automatically, so an agent can already walk much of the app with `tca ls` / `tca do`, and `tca devtools` shows every action with diffs. The generic oracles are already on: crashes, TCA's own runtime warnings (an action sent to a dismissed child, an `unimplemented` dependency) and stuck effects.

Where it gets harder in a real app:

- **Internal state.** Explicit descriptors can't use key paths to internal properties from another module. Read them by reflection, or make them public to the harness module.
- **State the views own.** Toggles bound straight to `@Shared` from a view, map state written by `MKMapView`, and focus have no action. Expose a binding action that writes the same storage, or accept that only the simulator rung sees it.
- **Payload actions.** Actions with arguments need `@HarnessOperation` or an explicit operation with a `@HarnessSchema` input. Operations can also build their action from what's on screen (`action: { state in .select(state.item) }`).
- **View lifecycle.** A headless host has no views, so it must send what they send: `.task`/`onAppear` when a screen appears, and a sheet's `onDismiss` when it goes away. Otherwise logic that only runs on those actions only runs on the simulator rung.
- **Time.** Long timers (polling, refresh intervals) are easier to drive with explicit operations ("Let a minute pass") than to wait out.

### How much of the app can an agent reach?

`tca exposure` answers that per feature path. The descriptor's catalog lists every feature it can mount, so screens no run has reached show up too. Each feature lists:
- the operations it declares, and how many dispatches ran each
- the action cases no operation sends, with why

`@HarnessFeature` fills that last list itself (`ignored`, `unannotated`, `binding`, `unsupported payload`, `multiple payloads`). Explicit descriptors declare their own with `.unexposed("case", reason: "...")`.

On day one, run it against the app (`tca exposure --port 8767`) and read the unexposed list as a to-do list. On a hundred screens, sort it by reason: `unannotated` and `unsupported payload` are decisions nobody has made yet; `ignored` is a decision someone made. Typical outcomes:
- **Worth exposing:** whole screens no run reaches, and flows that need a gesture the harness can't make. For those, add an operation that sends the same actions the gesture would.
- **Worth a journey:** exposed operations no run has exercised, especially the app's core loop.
- **Fine to leave:** lifecycle, effect and response actions that views and effects send themselves, and actions that only call out to the system (file pickers, opening another app).

## Step 2: route the network (a day per backend)

Route the app's `URLSession` through the harness. With one API client dependency this is one override.

```swift
$0.urlSession = URLSession(configuration: HarnessNetwork.configure(.ephemeral))
HarnessNetwork.install()                                  // also covers URLSession.shared
HarnessNetwork.shared.liveGuard = .readOnly(hosts: ["api.example.com"])   // before recording from a real backend
```

From then on every harness run blocks the network unless told otherwise. Record fixtures by running journeys against a backend with `tca fixtures record journeys/*.toml --target live --sanitize sanitize.py`. The live guard refuses anything but reads. Then write `match.json` for what varies between runs:

- `path_templates` for ids: `/books/{id}` turned Shelf's 39 per-id cassettes into 5.
- `ignore_query` for volatile parameters such as timestamps, coordinates or random cache-busters, which otherwise never match exactly.
- `ignore_body` for writes whose acknowledgement doesn't depend on the body.
- `pagination` with a terminal page, instead of hand-written empty pages.

`tca fixtures coverage journeys/*.toml --strict` fails whenever a request was blocked or only matched by fallback, which is the signal a fixture is missing or a rule is wrong. Commit the sanitized cassettes, never the raw ones.

## Step 3: invariants on the features that matter (an hour each)

Rules a user would notice if broken: a badge that disagrees with its list, duplicate rows, a spinner with no request in flight, a total that doesn't match its items. They live on the descriptor next to the feature, are checked after every action, and turn every journey and every random walk into a test.

```swift
.invariant("unread badge matches the list") { $0.unreadCount == $0.items.filter { !$0.isRead }.count }
```

## Step 4: journeys for the core flows (recorded, not written)

Have an agent do the flow with `tca do` while `tca record` captures it. A recorded journey pins:
- the steps, by label
- the checks on what the user sees
- the requests each step makes (`requests = ["GET /cards", "POST /cards/{id}/lock"]`), which is the contract a server-driven screen most often breaks

When a flow changes, the run fails with the current screen and the goal, and an agent re-solves it.

To pick the flows, and to see what is still uncovered once they exist, run `tca exposure --journeys 'journeys/*.toml' --reports explore.jsonl`. On Shelf:
- **Journeys alone:** the first eight journeys exercised 17 of 26 operations (65%).
- **Adding explore:** a 20-run explore report brought that to 23 (88%).
- **The last gaps:** the three left were Retry buttons that only appear after a failed load. `tca chaos` checks they are offered but doesn't press them, so each got a journey with a `[[faults]]` entry that taps Retry (`retry-load` with the fault `at = "launch"`, `retry-stats`, `retry-goal`). The eleven journeys exercise 20 (77%).

`--min-exercised 75` makes it a gate.

## Step 5: let the patterns find bugs (headless)

The headless host runs the real reducers with no UI. Modules that import UIKit build for Mac Catalyst. At about 70 actions per second:

- `tca explore` walks random operations with generated arguments and shrinks each finding to a minimal journey. `--races` dispatches while requests are in flight.
- `tca chaos` fails each request in turn (including at launch) and flags the user being stranded. `--reorder` delivers responses out of order.
- `tca determinism` and `tca diff` (headless vs simulator) find hidden nondeterminism and logic that only runs when views exist.

The [Shelf ladder](../examples/shelf/README.md) shows which pattern catches which kind of bug: stuck saves, double submits, stale searches, badges that drift, responses delivered to closed screens.

## Vanilla SwiftUI screens

Screens built on `@Observable` models use the same descriptors. Mount them inside the TCA app with `.model("name", { $0.model }, descriptor:)`, or wrap them in `Hosted<Model>`. With `Hosted`, the store owns their lifecycle: calls run as effects, are cancelled on dismissal and appear in the timeline. See [Vanilla SwiftUI models](../TCAHarness/README.md#vanilla-swiftui-models).

## Rules worth keeping

- Don't record from a production backend without `liveGuard`, and don't commit raw recordings.
- Seed what varies (`harnessDeterministic()`), isolate storage per run, and fix the location and clock, so runs are reproducible.
- Check what the user sees, not internals. Labels and published state change less often than code.
- Keep the generic oracles on everywhere. Invariants, reported issues and stuck effects catch most bugs, more than journey checks do.
