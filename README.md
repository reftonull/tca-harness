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

TCA already enforces the hard part: actions in, state out, one place where state changes. That's the contract Shopify built by hand for [Reflex](https://shopify.engineering/reflex). The harness adds the introspection layer on top of the store you already have.

## See it in a real app

The [isowords integration](examples/isowords/README.md) embeds the harness in the upstream app's original AppDelegate store. A model starts an unlimited game, selects cube faces and submits a word through the actual game reducer.

**Recorded result: SUN accepted for 12 points.** [Watch the gameplay](examples/isowords/recordings/actual-isowords-gameplay.mp4) · [See the embedding](examples/isowords/EmbeddedIsowordsHarness.swift) · [Review the entry-point patch](examples/isowords/app-entry.patch) · [Browse a recorded run](examples/isowords/recordings/interpretable-run.html)

isowords is fetched at a pinned revision during setup; its source and assets are not vendored and keep their own license.

## Add it to your app (TCA 1.x)

Add this repository as a Swift package and link **TCAHarnessTCA1**. Annotate your features:

```swift
import TCAHarnessTCA1

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

To run the same reducers with no UI, call `try await store.harness(RootFeature.self).runHeadless(port: 8790)` from a small executable. The same descriptors and CLI work with or without a UI, which makes agent loops and behavior tests fast. See [Run headless](TCAHarnessTCA1/README.md#run-headless).

- `@HarnessSchema` generates typed argument schemas for payload actions.
- `@HarnessIgnore` and redaction keep fields out of observations.
- Explicit `FeatureDescriptor`s handle unusual scopes, availability rules and completion. App state does not need to be `Codable`.

[Package guide](TCAHarnessTCA1/README.md) · [Protocol and transport](TCAHarness/README.md) · [Agent skill for integrating it](skills/integrate-tca-harness/SKILL.md)

For TCA 2 (`@Feature`, currently a private beta), see [TCAHarnessTCA2](TCAHarnessTCA2/README.md).

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
tca diff journeys/add-book.toml --targets headless,ui
```

[Testing guide](docs/testing.md) · [Command reference](cli/README.md#behaviour-tests) · [test-tca-app skill](skills/test-tca-app/SKILL.md)

The [Shelf example](examples/shelf/README.md) plants eight bugs, one for each pattern, behind `SHELF_BUGS`. `examples/shelf/run_ladder.sh` runs every pattern on the headless host, the simulator and a live local backend, and prints which pattern caught which bug.

### Model-driven goals

`tca run` loops toward a goal: observe, let a model choose one offered operation, fill its arguments, dispatch, repeat until an **app-defined predicate** verifies the result. The model never decides that it succeeded.

```sh
tca setup      # pick a provider and store the key in ~/.config/tca-harness/model.env (0600)
tca run --app --port 8767 --goal 'Start an unlimited solo game' --verify gameReady
```

Two providers are supported: [Router](https://router.com) (its `/systemone` choice classifier plus `/responses`), or any OpenAI Responses API-compatible endpoint. [Details](cli/README.md#model-driven-goals)

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
tca trace --input /tmp/run.jsonl --output /tmp/run.html
```

The offline viewer shows each goal, the offered operations, the model's choice, typed arguments, receipts, state changes and timing.

## Safety

The listener binds `127.0.0.1` only, has no authentication, and exists only in Debug builds launched with `TCA_HARNESS=1`. Any local process can drive the app while it runs. See [SECURITY.md](SECURITY.md).

## Status

Early and experimental. The protocol may change before 1.0.

- **Requirements:** Swift 6.3+, iOS 17+ / macOS 14+, TCA 1.13+ (tested with TCA 1.26 on Swift 6.4; the isowords example pins 1.26.2). TCA 2 support tracks the private beta.
- **Not covered by generated descriptors:** payload actions without an annotation, child state/action names that don't match, and some unusual scopes; use explicit descriptors.
- **App-defined:** availability, privacy projections, effect completion and cancellation.

## Repository layout

| Path | Purpose |
| --- | --- |
| [TCAHarness](TCAHarness) | Model-independent session, JSON schemas, receipts and loopback transport |
| [TCAHarnessTCA1](TCAHarnessTCA1) | Descriptors, runtime and macros for TCA 1.x (root `Package.swift`) |
| [TCAHarnessTCA2](TCAHarnessTCA2) | The same for TCA 2; separate package |
| [cli](cli) | `tca` command-line client, standard-library Python |
| [examples/isowords](examples/isowords) | Reproducible integration into an existing app |
| [skills](skills) | Agent skills for integrating the harness and recording app behaviour |
| [DecisionsTCA](DecisionsTCA), [DecisionsPackage](DecisionsPackage) | TCA 2 task demo app |
| [prototypes](prototypes/README.md), [recordings](recordings), [docs/research](docs/research) | Earlier experiments, recordings and design notes |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
