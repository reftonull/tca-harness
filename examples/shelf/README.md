# Shelf: every testing pattern, with planted bugs

Shelf is a small TCA 1.x reading-list app built to demonstrate [the testing patterns](../../docs/testing.md) on all three rungs. It loads books from a JSON backend, shows an unread badge and a "new" dot, searches with a debounce, adds books in a sheet (with an error banner and Retry), and marks a book read or deletes it.

Two of its screens are vanilla SwiftUI, written the way a team without TCA writes them: an `@Observable @MainActor` model with async methods over a plain client struct, no TCA inside. They get the same journeys, chaos, exploration and invariants as the TCA features (see [Vanilla SwiftUI screens](#vanilla-swiftui-screens)).

Ten bugs are planted in it. Each is a single `if bugs.contains(...)`, off by default, enabled with `SHELF_BUGS` (a comma-separated list, or `all`). With no bugs every pattern passes. With `SHELF_BUGS=all` each pattern catches the bug it was planted for.

```sh
cd examples/shelf
./run_ladder.sh               # builds, runs everything twice (no bugs, all bugs), prints the matrix
./run_ladder.sh --skip-ui     # leave out rung 2 (the simulator)
```

## The planted bugs

| Bug (`SHELF_BUGS=`) | What's wrong | Pattern | Rung | Expected finding |
| --- | --- | --- | --- | --- |
| `stuck-save` | A failed save leaves the editor spinning: no error, no Retry, Cancel disabled | Fault injection, `tca chaos journeys/add-book.toml` | 1 | `stuck`: `root/addBook/save still running after 5s`, and the `saving means a save is in flight` invariant |
| `double-save` | Save isn't disabled once the book is submitted | Exploration, `tca explore` | 1 | `invariant: no duplicate books`, shrunk to `Add book, Set title, Save, Save` |
| `badge-drift` | Marking a book read doesn't update the unread badge | Invariant, during `journeys/mark-read.toml` | 1, 3 | `invariant: unread badge matches the list` |
| `chatty-search` | Search sends an analytics event per keystroke instead of per search | Network discipline, `journeys/search.toml` budget | 1, 3 | `budget: 3 requests, budget 2` |
| `wall-clock` | New books are stamped with `Date()` instead of `@Dependency(\.date)` | Determinism, `tca determinism journeys/add-book.toml` | 1 | `differs after step 4 "Save"`: `books[3].addedAt` |
| `view-only-seen` | Only the SwiftUI view's `.onAppear` clears the "new" dot; the reducer's `.task` no longer does | Rung differential, `tca diff --targets headless,ui` | 1 vs 2 | `differs at launch: hasNewBooks: true vs false` |
| `late-delete` | Delete closes the detail first, then routes the response to it after it's gone | Generic issue oracle, `journeys/delete-book.toml` (and `tca explore`) | 1, 3 | `issue`: TCA's `An "ifLet" ... received a presentation action when destination state was absent` |
| `stats-stuck` | Reading stats (vanilla, `Hosted`): a failed load leaves the spinner on, with no error and no Retry | Fault injection, `tca chaos journeys/view-stats.toml` | 1 | `stranded: neither "Refresh" nor a retry of "Reading stats" offered within 5s`, for every hard fault on the first `GET /stats` |
| `goal-drift` | Reading goal (vanilla, `.model`): saving doesn't recompute the progress percentage | Invariant on the model descriptor, during `journeys/set-goal.toml` (and `tca explore`) | 1 | `invariant: root/goal: progress matches the goal`; explore shrinks it to `Reading goal, Set goal, Save goal` |
| `v2-contract` | Server-side: `server.py --v2` renames `author` to `writer` | Contract check, `tca journey run --network record` against the v2 server | 3 | `issue at launch: GET /books returned an unexpected shape: missing key 'author'` |

The bug list is in [Models.swift](Sources/ShelfCore/Models.swift) (`ShelfBug`). Grep for `bugs.contains` to see each one.

## Layout

| Path | What |
| --- | --- |
| [Package.swift](Package.swift) | `ShelfCore` (features) and `shelf-headless`, depending on the root harness package by path and TCA 1.26+ |
| [Sources/ShelfCore](Sources/ShelfCore) | `Shelf`, `AddBook`, `BookDetail`, the API and analytics clients, and the vanilla models `StatsModel` and `GoalModel` over `ReadingAPI`. Imports neither SwiftUI nor UIKit |
| [Sources/ShelfCore/ShelfHarness.swift](Sources/ShelfCore/ShelfHarness.swift) | Everything the harness sees: operations with labels and availability, invariants, the harness-routed `URLSession`, deterministic dependencies |
| [Sources/shelf-headless](Sources/shelf-headless/ShelfHeadless.swift) | Rung 1 host: the same reducers in a native macOS process |
| [App](App), [project.yml](project.yml), [flowdeck.json](flowdeck.json) | Rung 2: SwiftUI views over ShelfCore; xcodegen spec; FlowDeck config for the iPhone 17 Pro simulator |
| [server.py](server.py) | The backend: in-memory books CRUD plus `/events`, `/stats` and `/goal`, standard library only |
| [harness.toml](harness.toml) | Targets `headless`, `ui` and `live` |
| [journeys](journeys) | `add-book`, `mark-read`, `delete-book`, `search`, `retry-after-error`, and for the vanilla screens `view-stats`, `set-goal` |
| [fixtures/shelf](fixtures/shelf) | Cassettes recorded from `server.py`; [record_fixtures.sh](record_fixtures.sh) re-records them |
| [ladder.py](ladder.py), [run_ladder.sh](run_ladder.sh) | Run every pattern for both bug settings and print the matrix |

## How it's wired

**Descriptors.** `@HarnessFeature` generates each feature's observation. Operations are declared in `ShelfHarness.swift` instead of with `@HarnessOperation`, because they carry the availability the views enforce: a sheet covers the list (root operations and the book rows go away), and the editor's controls are disabled while saving and replaced by Done once saved. Availability is what lets `tca chaos` tell "the user can still do something" from "the user is stuck", and lets `tca explore` only try what a user could. Long-running operations have completion predicates (`Save` runs until the save answers, `Search` until the debounce applies), so journey steps, determinism and diff compare settled state.

**Invariants** live on the root descriptor: the unread badge equals the number of unread books, no two books share an id, and the editor never shows "saving" without a save in flight. The vanilla models carry their own, on their model descriptors: the goal's progress percentage matches the goal, and the stats' read and unread add up to the total.

**Network.** Every client uses one `URLSession` built with `HarnessNetwork.configure(.ephemeral)`. Under the harness it replays `fixtures/shelf`, records, injects faults and blocks anything unexpected. The base URL comes from `SHELF_API` (default `http://127.0.0.1:8799`). Responses are treated as acknowledgements: the app keeps the book it sent, so replay serves any book's request from the recording for its path. A response of the wrong shape (well-formed JSON, missing key) is reported with `reportIssue` as a contract problem. Invalid JSON is an ordinary failure.

**Determinism.** Both hosts apply `harnessDeterministic()` (seeded `uuid`, fixed `date`) and start listening only after the first load finishes. Every run, and both rungs, then start from the same state.

**Lifecycle.** The headless host sends `Shelf.Action.task`, which is what `ShelfView`'s `.task` sends. It does not send `.markShelfSeen` (the view's `.onAppear`). With the bug off, `.task` already clears the dot, so the two rungs agree.

## Vanilla SwiftUI screens

[StatsModel.swift](Sources/ShelfCore/StatsModel.swift) and [GoalModel.swift](Sources/ShelfCore/GoalModel.swift) import only Foundation and Observation. They call [ReadingAPI](Sources/ShelfCore/ReadingAPI.swift), a struct of closures passed to their initializers, which shares the harness-routed `URLSession` with the TCA clients, so replay, recording, faults and request budgets apply unchanged. Their descriptors, a few lines each, are in `ShelfHarness.swift`: operations with the availability the views enforce, and invariants. The views ([ReadingViews.swift](App/ReadingViews.swift)) take the model and nothing else.

The two screens are hosted the two ways a TCA app can host a vanilla screen:

| Screen | Host | What it shows |
| --- | --- | --- |
| Reading stats (`GET /stats`, Refresh) | `@Presents var stats: Hosted<StatsModel>.State?`, `.ifLet(\.$stats, action: \.stats) { Hosted<StatsModel>() }`, descriptor `Hosted.descriptor(StatsModel.harnessDescriptor)` | Every call is an action and an effect: the timeline shows `stats.presented.perform.load`, `stats.presented.finished.load` and the model's changes, the store starts the first load (`.call("load")`) and dismissing the sheet cancels it |
| Reading goal (`GET`/`PUT /goal`) | `var goal: GoalModel?` in `Shelf.State`, `.model("goal", { $0.goal }, descriptor: GoalModel.harnessDescriptor)` | The lighter option: operations call the model directly. Journeys, explore and invariants work the same; its calls aren't in the timeline and nothing cancels them on dismiss |

Both screens' first load is started by the shelf when it presents them, not by the view's `.task`, so the headless host (which has no views) behaves like the app.

## Run the pieces by hand

```sh
cd examples/shelf
swift build                                     # rung 1 host
python3 server.py &                             # only needed for rung 3 and re-recording

../../scripts/tca journey run journeys/*.toml   # replay, headless
SHELF_BUGS=badge-drift ../../scripts/tca journey run journeys/mark-read.toml
SHELF_BUGS=double-save ../../scripts/tca explore --fixtures fixtures/shelf --runs 30
SHELF_BUGS=stuck-save ../../scripts/tca chaos journeys/add-book.toml
SHELF_BUGS=wall-clock ../../scripts/tca determinism journeys/add-book.toml
SHELF_BUGS=stats-stuck ../../scripts/tca chaos journeys/view-stats.toml
SHELF_BUGS=goal-drift ../../scripts/tca journey run journeys/set-goal.toml

xcodegen generate && flowdeck build --config flowdeck.json
SHELF_BUGS=view-only-seen ../../scripts/tca diff journeys/mark-read.toml --targets headless,ui

../../scripts/tca journey run journeys/search.toml --target live --network record   # rewrites fixtures/shelf
```

`--network record` rewrites the committed cassettes. To re-record all of them against fresh servers, run `./record_fixtures.sh`. `ladder.py` runs rung 3 in a scratch copy, so the ladder never touches them. [fixtures/record-sweep.toml](fixtures/record-sweep.toml) is not a test. It touches every endpoint for the seed books and the first six books a walk can add (their ids come from the seeded uuid generator), so a clean `tca explore` never makes a request without a fixture.

To drive the app yourself, launch it with `flowdeck run --config flowdeck.json --launch-env 'TCA_HARNESS=1 TCA_HARNESS_PORT=8792'` and use `../../scripts/tca ls --port 8792`.
