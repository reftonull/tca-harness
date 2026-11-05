> Historical task experiment. For the current connected-app CLI, see [cli/README.md](../../cli/README.md); for a full app integration, see [isowords](../../examples/isowords/README.md).

# TCA / Jev harness — throwaway prototype

Question: can a persistent TCA 2 runtime offer finite operations to a fast decision
model, route them into a spawned child, and verify asynchronous completion without
an iOS simulator?

## Run

From the repository root:

```sh
./scripts/tca
```

This builds if needed and opens a small interactive terminal shell. Choose a
number to dispatch an offered operation. State is shown after each command.
Use `observe` to refresh after asynchronous changes, `wait` to wait for the last
operation, or `quit` to leave. Everything lives in memory and ends with the process.

Requires macOS 26+, Xcode 26.4.1 / Swift 6.3+, FlowDeck, XcodeGen, Python 3, and
GitHub access to the private TCA26 package. The current upstream provides a Swift
6.3 compatibility manifest. Builds use FlowDeck; XcodeGen generates only the
prototype command-line project. The root iOS FlowDeck selection is preserved.

A model-free scripted scenario:

```sh
./scripts/tca demo
```

A real Jev run with deterministic outcome verification:

```sh
./scripts/tca run \
  --goal 'Complete every task, then open the archive and save a snapshot containing all completed tasks. Leave the saved archive open.' \
  --verify allCompletedAndArchived
```

The CLI reads `RAMP_ROUTER_API_KEY` and `RAMP_ROUTER_BASE_URL` from the environment
or `~/.config/jev/router.env`, with environment variables taking precedence. Keys
never enter the Swift app, host protocol, model evidence, or repository. Model
calls use Router `/v1/systemone`, defaulting to `jev-1.14.0`; use `--model` to change
it. `demo`, manual dispatch, and verification need no model or key.

The loop prints JSON-line decision, dispatch, wait, and verification events. It
allows up to eight decisions by default (`--max-steps`, capped at 20), bounds HTTP
requests and waits, and stops on model abstention or execution failure. It uses a generative model for schema-bearing operations, but does not implement
a general planning fallback or a calibrated confidence threshold. A model
abstention is not reported as verified success. Without a registered `--verify`
condition the CLI cannot prove an arbitrary natural-language goal.

In the manual shell, `goal Complete the groceries task` asks Jev for one step.
The shell is for exploration; `run` is the bounded automatic loop.

## What actually runs

- `DecisionsPackage/Sources/DecisionDomain/TaskList.swift` is the shared domain used
  by both the iOS app and native host.
- `TaskList` manages tasks and an optional `Spawn<Archive>`.
- `Archive` has its own action domain. Its save changes status to `saving`, then
  a TCA task writes `saved` after a simulated 350 ms operation. Saving is an
  in-memory snapshot demonstration, not disk persistence or a network save.
- `Sources/Harness.swift` owns a long-lived main-actor TCA `Store`, without any
  SwiftUI view or application window. A headless host does not require StoreActor.
- [`cli/tca.py`](../../cli/tca.py) communicates with that process through JSON lines and optionally calls
  Jev. Its blocking stdin reader lives off the store actor, so effects keep
  progressing when no commands are arriving.

The headless store is independent of the running iOS app's store. The CLI does
not remotely control the simulator. The iOS UI presents the same archive behavior
for manual comparison. Networking to an app-hosted store is a later experiment.

## Wire interface

Start `./scripts/tca protocol`. Send one JSON object per line; receive one JSON
response per line on stdout. Build output goes to stderr.

```json
{"method":"observe"}
```

The observation includes a session ID, revision, tasks, optional archive status,
and currently valid candidate IDs. Copy the current session and revision into a
dispatch request:

```json
{"method":"dispatch","sessionID":"COPY_FROM_OBSERVATION","requestID":"my-request-1","candidateID":"root/completeButtonTapped/groceries@COPY_FROM_OBSERVATION","revision":0}
```

For an asynchronous receipt, use its request ID:

```json
{"method":"wait","sessionID":"COPY_FROM_OBSERVATION","requestID":"my-save-1","timeoutMs":3000}
```

Waits are capped at ten seconds. A timeout leaves the operation running; it does
not claim cancellation. Closing or resetting the archive while saving dismounts
the child and cancels its work. Terminal receipt states remain terminal after
later child closure.

Independent state predicates are provided for this domain:

```json
{"method":"verify","condition":"task:groceries"}
{"method":"verify","condition":"allCompleted"}
{"method":"verify","condition":"archiveSaved"}
{"method":"verify","condition":"allCompletedAndArchived"}
```

`archiveSaved` also requires the archive's task IDs to match the currently
completed tasks; a saved but obsolete snapshot does not satisfy it.

The host and the iOS app use descriptors generated by `@HarnessFeature` on `TaskList`
and `Archive` ([TCAHarnessTCA2](../../TCAHarnessTCA2/README.md), attached in
`DecisionHarness/TaskHarness.swift`). Candidates are `root/completeButtonTapped/<taskID>@…`,
`root/openArchiveButtonTapped@…`, `root/archive/saveButtonTapped@…`,
`root/closeArchiveButtonTapped@…`, `root/resetButtonTapped@…`, plus typed create and edit
operations. The part after `@` identifies the mounted feature instance. Only currently valid
operations are offered. Recordings made before this change show the earlier hand-written
catalog (`tasks/complete/<taskID>`, `archive/<generation>/save`, …).

## Concurrency and identity

Validation and dispatch execute synchronously on the store actor with no await
between them. The host compares the relevant state projection before every
observation/dispatch; revisions advance when that projection differs, including
async writes that did not send an action. These are observation revisions, not a
complete log of every intermediate mutation or a guarantee against unseen ABA
changes in an arbitrary feature.

A candidate selected at an old revision is rejected. Each spawned archive is a new
feature instance with its own candidate IDs, so a closed child's command cannot
address a replacement child. Session IDs reject commands intended for another
process. Matching retry request IDs return the existing receipt; reusing an ID
with different arguments is rejected. Receipts and deduplication are process-local
and in memory, not crash-safe exactly-once delivery.

## What was learned

The model-free scenario successfully exercised candidate dispatch, duplicate
requests, request-ID conflicts, stale revisions, bounded waits, async progress
while stdin is idle, spawned-child lifetime invalidation, and cancellation on
child dismount. It finished with all tasks complete and the current snapshot saved.

A live Jev 1.14 run completed the same happy-path goal in five decisions and
1,710 ms end to end, including the simulated 350 ms save. Individual model calls
were 219–382 ms. This is one observed run, not a latency or accuracy benchmark.

The core design is viable for these two features: a real TCA runtime can own the
execution session while Jev selects finite operations outside it. More features
still need explicit observations, candidate adapters, and outcome predicates.
Public runtime lifetimes help route child commands and cancel work. A root action
interceptor alone would not capture the child action or its direct async write.

Next questions: composition of adapter catalogs through preferences, real I/O
failures, feature visibility policy, richer typed arguments and a generative
fallback, plus a transport into the real iOS app store.

## Build / iOS validation

```sh
./scripts/tca build
flowdeck build
flowdeck test --only DecisionsTCATests
```

`./scripts/tca build` forces a native rebuild. The generated macOS project and its
build products are ignored. The prototype is intended to remain on a throwaway
branch and is not a production automation interface.

## Drive the visible iOS app through its actual store

The same harness is now embedded through a separate local Swift package,
[`TCAHarness`](../../TCAHarness/README.md). The task adapter lives in the
`DecisionHarness` product. The iOS app passes its existing root store to it.

Launch the app on the saved simulator with the development listener enabled:

```sh
flowdeck run --launch-env TCA_HARNESS=1
```

Then connect from another terminal:

```sh
./scripts/tca observe --app
./scripts/tca shell --app
./scripts/tca run --app \
  --goal 'Complete every task, then open the archive and save a snapshot containing all completed tasks. Leave the saved archive open.' \
  --verify allCompletedAndArchived
```

`--app` skips native-host building/launching and connects to `127.0.0.1:8765`
(`--port` overrides it). The store persists after the CLI disconnects because the
app owns it. Successive CLI invocations operate on that same app session. Manual
UI edits are observed by the next CLI call. `./scripts/tca demo --app` resets the
app's task state before exercising the scripted scenario.

For a readable recording, `--step-delay 0.7` adds explicit pacing between steps;
those delays are included in elapsed time. With no `--app`, the original headless
mode remains available and owns an independent store.

The app shows listener status and request count while the development listener is
enabled. This listener is unauthenticated loopback-only and starts only in an
explicitly enabled Debug simulator launch. No Router key enters the app.

Earlier sections describing the headless store remain accurate for default mode;
`--app` is the new path into the visible UI. Observation and operations come from the
generated descriptors; the app supplies only its verification rules.

## Hybrid Jev + generative LLM prototype

Run the complete example against the visible app (or omit `--app` for headless):

```sh
./scripts/tca hybrid-demo --app
```

This explicitly resets the demo tasks, then runs three goals:

1. Create a high-priority Work task titled `Email Sarah about launch`, due
   October 30, 2026, with original friendly notes addressed to Sarah.
2. Edit that existing task: low priority, Personal, November 2, 2026, and a newly
   generated checklist mentioning slides and an agenda.
3. Complete that task, open its archive, and save the snapshot using finite
   Jev-selected operations without more text generation.

Each parameterized operation advertises `argumentSchema` in the observation.
Jev chooses an operation ID; the CLI then calls Router `/v1/responses` with a
schema-constrained output request, using `claude-haiku-5-5` by default
(`--argument-model` overrides it). The app receives only the resulting argument
object, rechecks revision/availability, validates schema and domain rules, and
sends a typed TCA action. Open-ended notes are actually generated, not selected
from a fixed list. Titles, notes, priorities, projects, and dates are rendered by
the ordinary SwiftUI task list.

Try your own goal from the shell using `goal ...`, or select a numbered
parameterized operation and enter its arguments as JSON. For automatic runs:

```sh
./scripts/tca run --app \
  --goal 'Create a new task titled exactly "Email Sarah about launch", high priority, in Work, due October 30, 2026. Write two friendly sentences of notes addressed to Sarah about coordinating the launch.' \
  --expect-task prototypes/tca-harness/fixtures/launch-task.json
```

`--expect-task` loads a local fixture with exact task `fields`, optional
`notesMinLength`, and optional `notesContain` strings. This fixture is not sent
to either model. Verification compares actual observed state against those
criteria. It checks fields/content markers, not overall writing quality.

Argument validation can be explored without any model calls:

```sh
./scripts/tca arguments-demo
```

It exercises blank titles, impossible dates, unsupported enum values, oversized
text, missing/unknown fields, argument-aware retry deduplication, and valid typed
creation/editing. The ordinary `demo` still exercises the finite-action path.

`arguments_generated` events contain generated values, actual model identity,
latency, and reported usage/cost. Decision and generation timings are logged
separately; total elapsed time includes both stages. The first successful
headless creation took 179 ms for Jev plus 2,304 ms for generation (2,487 ms total).
That is one run, not a benchmark. Dates in these fixtures are explicit so results
are reproducible; ambiguous natural-language dates can still be misinterpreted
by the generative model even when the resulting ISO date is structurally valid.

The original scripted scenarios can now offer additional create/edit operations;
their availability does not force a generative call unless selected.

The recorded live-app `hybrid-demo` succeeded with five Jev calls and two
generative calls. It took 8,855 ms including 3,000 ms explicit pacing, or about
5,855 ms excluding pacing. Generation took 1,689 and 2,787 ms; the five Jev
choices totaled 856 ms. See
`recordings/hybrid-summary.json`.

## Typed runtime commands

For a host using HarnessRuntime (the isowords app listens on 8766):

```
./scripts/tca inspect --app --port 8766 --path root/home/settings
./scripts/tca dispatch --app --port 8766 --candidate 'ID_FROM_INSPECTION' --arguments '{"value":0}'
./scripts/tca wait --app --port 8766 --request-id 'RECEIPT_REQUEST_ID'
./scripts/tca cancel --app --port 8766 --request-id 'RECEIPT_REQUEST_ID'
```

Dispatch supports `--revision` and `--request-id` for explicit stale-state guards and retry identity. Arguments may be nested JSON objects, arrays, numbers, booleans, strings and null according to the operation schema. Generated enum/scalar inputs use a `value` wrapper; generated struct inputs use their fields directly. Cancellation requires a registered reducer cancellation action. Capability inspection is available on the typed runtime; the original headless demo exposes the simpler session interface.

## Live text-input examples

From the repository root, launch the existing Decisions task app with its listener enabled:

```
flowdeck run --launch-env TCA_HARNESS=1
python3 prototypes/tca-harness/typing_examples.py
```

The runner resets the throwaway demo tasks and performs three Jev + Haiku 5.5 examples:

1. Create `Book a table for Zoë 🍜` with exact punctuation and notes.
2. Generate an original five-item, multiline implementation checklist for `Prepare harness demo`.
3. Rename the first task to `Book a table for Zoë & 李 🍜`, replace its notes with two exact lines, and change priority while preserving project, due date and all other records.

Each example verifies resulting reducer state, including Unicode preservation, newlines, task counts and untouched records. This is text entry through typed create/edit actions, not keyboard-event simulation. The isowords checkout has no text-entry controls; these examples use the existing task app.

The JSON-lines transcript contains model choices and generated arguments, and `text-input-final-state.json` contains the full text (the UI truncates long notes). Argument generation took 1.718 s, 3.747 s and 1.577 s in this run; these are network-inclusive samples, not benchmarks.
