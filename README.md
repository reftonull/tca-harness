# TCA Harness

Let agents and tests use your [Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) app through its own store, without taps, screenshots or a simulator UI.

An agent asks the app what is on screen and gets back state as JSON plus the operations it can run there, each with a typed argument schema. It picks one, the harness validates the arguments and sends the real TCA action, and the UI updates from the same state.

```text
$ tca ls
Settings (root/home/settings)  revision 3

State:
{
  "haptics": true,
  "musicVolume": 0.5
}

Actions:
  setMusicVolume  - Set music volume  {value: number}
  disableHaptics  - Disable haptics
  binding/colorScheme/dark  - Set color scheme to dark
From root/home:
  dismissSheet  - Close the current Home sheet and return Home

$ tca do setMusicVolume '{"value": 0.25}'
```

```text
agent / CLI / test → loopback JSON → embedded runtime → your existing Store → your UI
                                          ↑
                         typed feature descriptors (macros or handwritten)
```

TCA already enforces the hard part: actions in, state out, one place where state changes. The harness adds the introspection layer on top of the store you already have, so the same descriptors serve an agent building a feature, a random walk hunting for bugs, and a journey that pins a flow.

[What it catches](#what-it-catches) · [Add it to your app](#add-it-to-your-app) · [Let your agent drive it](#let-your-coding-agent-drive-it) · [Test behaviour](#test-behaviour-not-implementation) · [Testing guide](docs/testing.md) · [Adopting in a large app](docs/adopting.md)

## What it catches

The [Shelf example](examples/shelf/README.md) is a small reading-list app with a REST backend and one planted bug per testing pattern, behind `SHELF_BUGS`. `examples/shelf/run_ladder.sh` runs every pattern headless, on the simulator and against a live local backend, and reports which pattern caught which bug. Each one is found without writing a test for it:

- **A failed save leaves the editor spinning** with no error and no Retry (`tca chaos`).
- **Save stays tappable while its request is in flight,** so a double tap adds the book twice (`tca explore --races`).
- **A slow search response overwrites a newer one** (`tca chaos --reorder`).
- **The unread badge drifts from the list** (an invariant).
- **Searching sends an analytics request per keystroke** (the step's pinned requests).
- **A delete response reaches a screen that already closed** (TCA's own runtime warning).
- **New items are stamped with `Date()`** instead of the date dependency (`tca determinism`).
- **A view's `onAppear` changes state that headless never sees** (`tca diff`).
- **The backend renames a field** (a contract check against the live server).
- **Two vanilla SwiftUI screens** get the same treatment.

With the bugs off, every pattern comes back clean. Earlier experiments, including model-driven play of the isowords game and the same game running headless about 24 times faster than in the simulator, are on the [`archive/experiments`](https://github.com/reftonull/tca-harness/tree/archive/experiments) branch.

## Add it to your app

Add this repository as a Swift package and link **TCAHarness**. Annotate your features:

```swift
import TCAHarness

@HarnessFeature
@Reducer
struct RootFeature { ... }
```

Then attach the harness to the store you already create, and keep a reference to it:

```swift
let harness = store.harness(RootFeature.self)
try harness.startIfEnabled()
```

Launch a Debug build with `TCA_HARNESS=1` (and optionally `TCA_HARNESS_PORT`, default 8765). Release builds compile the listener out.

To run the same reducers with no UI, call `try await store.harness(RootFeature.self).runHeadless(port: 8790)` from a small executable. The same descriptors and CLI work with or without a UI, which makes agent loops and behavior tests fast. See [Run headless](TCAHarness/README.md#run-headless).

Screens built on plain `@Observable` models use the same descriptors: mount them with `.model(...)`, or wrap them in TCA with `Hosted<Model>` so their calls run as effects and show in the timeline. See [Vanilla SwiftUI models](TCAHarness/README.md#vanilla-swiftui-models).

- `@HarnessSchema` generates typed argument schemas for payload actions.
- `@HarnessIgnore` and redaction keep fields out of observations.
- Explicit `FeatureDescriptor`s handle unusual scopes, availability rules and completion. App state does not need to be `Codable`.

[Package guide](TCAHarness/README.md) · [Protocol and transport](TCAHarnessCore/README.md) · [Agent skill for integrating it](skills/integrate-tca-harness/SKILL.md)

## Use the CLI

```sh
pipx install git+https://github.com/reftonull/tca-harness   # or run ./scripts/tca from a checkout
```

```sh
tca doctor --port 8767                  # is the app reachable and wired up?
tca ls --port 8767                      # focused feature, its state, its actions
tca do 'Open Settings' --port 8767      # run an action and print the new view
tca do setMusicVolume '{"value": 0.25}' --port 8767
```

`ls` focuses the deepest mounted feature, the way a user only sees the top of the stack, and lists the actions ancestors lend to it (back, dismiss, tab selection). `inspect`, `observe`, `dispatch`, `wait` and `cancel` expose the full protocol with revisions and request IDs.

### Let your coding agent drive it

Agents with a shell (Claude Code, Codex, Cursor) need nothing extra: `tca ls` and `tca do` are the interface. The [drive-tca-app skill](skills/drive-tca-app/SKILL.md) teaches the loop: look, act once, check the new state, and prove results with state rather than descriptions. Claude Code picks up this repo's skills automatically through `.claude/skills`; elsewhere, copy the skill folder into your agent's skills directory.

### Test behaviour, not implementation

A journey names a goal, the steps a user takes (by label) and what must be true afterwards. `tca journey run` replays it on a fresh launch with network fixtures, and every run also catches crashes, reported issues, broken invariants, unexpected requests, stuck effects and dead ends. Agents write journeys by solving the goal with `tca do` while `tca record` captures the steps.

```sh
tca journey run journeys/*.toml          # launch targets come from harness.toml
tca explore --runs 50                    # random walks; findings are shrunk to minimal journeys
tca chaos journeys/add-book.toml         # fail each request in turn
tca explore --races --runs 30            # double taps and dismissals while requests are in flight (replay latency)
tca chaos journeys/search.toml --reorder # responses out of order: does a stale one win?
tca diff journeys/add-book.toml --targets headless,ui
```

In an app where every screen calls the server, fixtures are the cost that grows with the app, so they're managed like code. `tca fixtures record` runs journeys against a backend (with a read-only guard for production) and sanitizes the result. `match.json` templates ids and ignores volatile parameters, and `tca fixtures coverage --strict` fails when a request was blocked or matched only by fallback. `tca exposure` shows, per feature, which actions an agent can't reach and which operations no run has exercised.

[Testing guide](docs/testing.md) · [Adopting in a large app](docs/adopting.md) · [Command reference](cli/README.md#behaviour-tests) · [test-tca-app skill](skills/test-tca-app/SKILL.md)

The [Shelf example](examples/shelf/README.md) plants eleven bugs behind `SHELF_BUGS`, one for each pattern (two of them races: a double save and a stale search) plus two in vanilla SwiftUI screens (`@Observable` models, one wrapped in TCA with `Hosted`). `examples/shelf/run_ladder.sh` runs every pattern on the headless host, the simulator and a live local backend, and prints which pattern caught which bug.

### Model-driven goals

`tca run` loops toward a goal: observe, let a model choose one offered operation, fill its arguments, dispatch, repeat until an **app-defined predicate** verifies the result. The model never decides that it succeeded.

```sh
tca setup      # pick a provider and store the key in ~/.config/tca-harness/model.env (0600)
tca run --port 8790 --goal 'Add "Dune" by Frank Herbert to my shelf' --verify 'onShelf:Dune'
```

Predicates are a `verify:` closure you pass to `store.harness(...)`; the example uses [Shelf's](examples/shelf/Sources/ShelfCore/ShelfHarness.swift). Two providers are supported: [Router](https://router.com) (its `/systemone` choice classifier plus `/responses`), or any OpenAI Responses API-compatible endpoint. [Details](cli/README.md#model-driven-goals)

### Watch every action live

Record the root reducer and open the devtools panel. Like Redux DevTools, it logs every reduced action, whether sent by a view, an effect or the agent, with the resulting state, a diff, effect lifecycles and the operations mounted afterwards.

```swift
let store = Store(initialState: AppFeature.State()) {
  AppFeature().harnessTimeline()   // inert unless TCA_HARNESS=1
}
```

```sh
tca devtools --port 8767   # then open http://127.0.0.1:8780
```

History is read-only. Payload values are hidden by default and snapshots go through the descriptor's observation, so redaction applies.

### Inspect a recorded run

```sh
tca run --port 8790 --goal '...' --verify '...' > /tmp/run.jsonl   # or any --report file from journey/explore/chaos
tca trace --input /tmp/run.jsonl --output /tmp/run.html
```

The offline viewer shows each goal, the offered operations, the model's choice, typed arguments, receipts, state changes and timing.

## Safety

The listener binds `127.0.0.1` only, has no authentication, and exists only in Debug builds launched with `TCA_HARNESS=1`. Any local process can drive the app while it runs. See [SECURITY.md](SECURITY.md).

## Status

Early and experimental. The protocol may change before 1.0.

- **Requirements:** Swift 6.3+, iOS 17+ / macOS 14+, TCA 1.13+ (tested with TCA 1.26 on Swift 6.4).
- **Scope:** TCA apps (1.13 and later), including screens built on plain `@Observable` models. Experiments (TCA 2 beta support, the isowords integration, earlier prototypes and design notes) live on the [`archive/experiments`](https://github.com/reftonull/tca-harness/tree/archive/experiments) branch.
- **Not covered by generated descriptors:** payload actions without an annotation, child state/action names that don't match, and some unusual scopes; use explicit descriptors.
- **App-defined:** availability, privacy projections, effect completion and cancellation.

## Repository layout

| Path | Purpose |
| --- | --- |
| [TCAHarness](TCAHarness) | What apps link: descriptors, macros, runtime, `@Observable` model support (root `Package.swift`) |
| [TCAHarnessCore](TCAHarnessCore) | Model-independent session, JSON schemas, receipts and loopback transport |
| [cli](cli) | `tca` command-line client, standard-library Python |
| [docs](docs) | [Testing guide](docs/testing.md), [adopting in a large app](docs/adopting.md) |
| [examples/shelf](examples/shelf) | A small app with planted bugs for every testing pattern, including vanilla SwiftUI screens |
| [skills](skills) | Agent skills: integrate the harness, drive an app, test it, record its behaviour |
| [scripts/tca](scripts/tca) | Runs the CLI from a checkout without installing it |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
