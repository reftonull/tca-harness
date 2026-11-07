# tca: the harness CLI

`tca` connects to a TCA app that embeds the harness listener. You can inspect the app, dispatch its typed operations, watch its actions, and optionally run a bounded model loop toward a goal. It needs Python 3.11+ and uses only the standard library.

## Install

From a checkout, no install is needed:

```sh
./scripts/tca doctor --port 8767
```

As a command on your `PATH`:

```sh
pipx install .                                   # from a checkout
uvx --from git+https://github.com/reftonull/tca-harness tca doctor --port 8767   # without installing
```

The package is named `tca-harness` and installs one console script, `tca`. Launch the app with `TCA_HARNESS=1` and, if needed, `TCA_HARNESS_PORT=8767`. The default port is 8765.

## Look and act: `ls` and `do`

```sh
tca ls --port 8767
tca do 'Open Settings' --port 8767
tca do setMusicVolume '{"value": 0.25}' --port 8767
```

`ls` prints the **focused feature** and its state as JSON. Below that it lists the actions you can run. The focused feature is the deepest mounted feature path, for example `root/home/settings`. Actions are grouped like this:

- **Actions:** operations on the focused feature, with a short argument summary when they take arguments.
- **From \<ancestor\>:** operations that ancestor features lend to the focused screen, such as closing a sheet, going back, or selecting a tab. The nearest ancestor comes first.

Focus rules:

- When two deepest features tie, the one offering operations wins.
- If that doesn't settle it, `ls` focuses their common ancestor and shows every tied branch. Collection rows such as `root/todos/<id>` are handled this way.
- `--path FEATURE` focuses a specific mounted feature.
- `--all` adds every other mounted operation, the feature list, and the whole root state.

State is looked up by walking the path through the observed state tree (object keys, collection element `id`s or indices, and enum `case`s). If a segment can't be resolved, `ls` shows the deepest state it could resolve and names that path.

`do ACTION ['{json}']` resolves `ACTION` in this order:

1. An exact operation ID, or an ID without its `@instance` suffix. These match anywhere.
2. An operation name relative to its feature (`dismiss`, `binding/name`), or its label, compared case-insensitively. Only focused and lent operations are searched; add `--all` to search every operation.

`do` then dispatches at the observed revision with a new request ID, waits up to 5 seconds for the receipt, and prints the new focused view. If the name is ambiguous or matches nothing, `do` lists the choices on stderr and exits with code 2 without dispatching. Rejections (`stale_revision`, `invalid_arguments`, ...) and `failed`/`cancelled` receipts also exit with code 2, except a `cancelled` receipt whose dispatching feature is no longer mounted: navigation such as isowords' Solo → Game closes the feature that sent the action, so `do` reports it as sent and exits 0. Arguments can also be passed with `--arguments`.

Output is plain text with no colors or progress lines. Add `--json` for machine-readable output: the view (`focus`, `statePath`, `state`, `operations[]` with `name`, `label`, `id`, `feature`, `scope`, `argumentSchema`), or for `do`, `{ok, candidateID, receipt, error, detail, view}`.

`ls` and `do` always connect to the app. While `tca record` is active, each successful `do` is also appended to the journey being recorded (see below).

## Behaviour tests

These commands run user-level tests against fresh launches of the app and apply the generic oracles after every step: **crash** (process exit or dropped connection), **issue** and **invariant** (reported by the app), **network** (a request blocked or without a fixture), **stuck** (a receipt still running after `--wait-ms`, default 5000), **rejected** (an offered operation refused for a reason other than a stale revision or invalid arguments) and **dead end** (nothing offered). The design and file formats are in [docs/testing.md](../docs/testing.md).

Every command prints a short plain-text summary, writes JSON lines with `--report FILE` (open them with `tca trace`), and exits 0 when nothing was found, 1 when something was, and 2 for usage or configuration errors. Findings are written as minimal journeys under `.tca/findings/`. Against a protocol v2 app, the issue, invariant and network oracles are skipped and the summary says so once.

### Targets: `harness.toml`

```toml
[targets.headless]
launch = ".build/debug/shelf-headless --port {port}"
port = "auto"                      # or a fixed port
ready = "TCA harness listening"    # output line meaning ready; without it the port is polled
ready_timeout = 30
restart = "per-run"                # or "never": one process (or an app already on the port) for every run
env = { SHELF_API = "http://127.0.0.1:8799" }
stop = "..."                       # optional command run after each process is stopped
```

The CLI finds `harness.toml` by searching upward from the journey file, then the current directory, and uses `--target NAME` (default `headless`, or the only target). Each run gets its own process group, killed afterwards. The launch command sees `TCA_HARNESS=1`, `TCA_HARNESS_NETWORK`, `TCA_HARNESS_CASSETTES`, `TCA_HARNESS_SEED` and `TCA_HARNESS_PORT` in its environment, plus `TCA_HARNESS_FAULTS` (compact JSON) when the run fails requests at launch. `{env}` expands to the same settings plus the target's `env` as `KEY=value` pairs for launchers that can't pass the environment on.

### `tca journey run`

```sh
tca journey run journeys/*.toml [--target headless] [--network replay] [--seed 0] [--report run.jsonl]
tca journey run journeys/add-book.toml --port 8790      # attach to a running app instead of launching
tca journey run journeys/add-book.toml --target ui --pace 1.2   # pause 1.2s after each step, e.g. to record it
tca journey run journeys/add-book.toml --target ui --keep       # leave the app running afterwards to inspect or record it
```

Each step is resolved exactly like `tca do` (label, name or ID among the focused and lent operations), dispatched and waited for. After each step the oracles run and the step's `expect` is checked, and a step's `requests` (for example `requests = ["GET /books", "POST /events"]`) are compared, in any order, with the requests the app logged until it went quiet again. A step that declares `requests = []` must make none, and `launch_requests` covers launch. At the end every `[checks]` expression must hold and `[budget] requests` is compared with the app's request log. `--pace SECONDS` (default 0) sleeps after each step and once more before the final checks, so a person or a screen recording can follow the run; it doesn't change what is checked. `--keep` leaves the app launched for the last journey running and prints its port and how to stop it. A launched app's output goes to a log file in the temp directory, so it survives the CLI exiting. Attaching with `--port` to an app that already uses the journey's fixtures doesn't reload them, so ordered recordings (`_1`, `_2`, …) carry on where the app is. Output is one line per passing journey and the first problem for a failing one:

```text
FAIL  Add a book  (journeys/add-book.toml)
  step 2 "Set titel": no offered operation matches
  current view:
    Editor (root/shelf/editor)  revision 1
    ...
  goal: Add a book called Dune and see it on the shelf
  remaining steps: "Set titel", "Save"
  hint: re-solve it: `tca record start journeys/add-book.toml`, reach the goal with `tca ls`/`tca do`, then `tca record stop`
```

A request mismatch names both sides:

```text
FAIL  Mark a book as read  (journeys/mark-read.toml)
  requests after step 3 "Mark as read": expected [PUT /books/{id}], made [PUT /books/2A3F0C1E-8C55-4E0B-9C5A-0B5D7F3A1103, GET /books] (unexpected GET /books)
```

Patterns are `METHOD /path`, where `{name}` is one path segment and `*` matches anything; a pattern without `?` ignores the query (`GET /books?*` matches any query). Faults with `at = "launch"` are passed in `TCA_HARNESS_FAULTS`, so they fail requests the app makes before the CLI connects. A journey with a goal but no steps fails as unsolved with the same hint. Check expressions allow attribute access, indexing, comparisons, `and`/`or`/`not`, arithmetic, generator expressions and `len`, `any`, `all`, `sum`, `min`, `max`, `sorted`, `set`; missing keys read as `None`.

### `tca record`

```sh
tca record start journeys/add-book.toml --goal "Add a book called Dune and see it on the shelf"
tca do "Add book" --port 8790
tca do "Set title" '{"value":"Dune"}' --port 8790
tca do Save --port 8790
tca record stop --check "Dune is on the shelf=any(b.title == 'Dune' for b in shelf.books)"
```

`start` writes `.tca/recording.json` in the current directory; run `tca do` from the same directory. Each successful `do` appends its step by label (falling back to the name or route when the label is ambiguous), with the requests the app made until the next `do` as its `requests` (`stop` waits for quiet to fill in the last step). Paths are templated (`PUT /books/{id}`) from `match.json` or, for numeric, UUID and long hex segments, by shape. Requests made before the first `do` are written as `launch_requests`, so start on a fresh launch. `stop` writes the journey, keeping the existing file's other keys (fixtures, network, checks, budget) so re-solving a broken journey only replaces its steps. Checks are validated before anything is written.

### `tca explore`

```sh
tca explore [--target headless] [--runs 50] [--steps 40] [--seed N] [--fixtures DIR | --journey FILE] [--shrink-trials 100]
```

Each run launches the app, then repeatedly picks a random offered operation and generates arguments from its schema: strings from a corpus with empty, whitespace, long, unicode and markup values (within `minLength`/`maxLength`), numbers at their bounds, enums, booleans, nulls for optional values, and nested arrays and objects. `--journey FILE` starts every walk from that journey's end state and uses its fixtures. The first finding of a run is shrunk with delta debugging, relaunching for every trial, to the shortest step list that reproduces the same finding, then written to `.tca/findings/<kind>-<n>.toml`. Findings are deduplicated by kind and message (or operation). The walk is reproducible from `--seed`.

```text
explore: 50 run(s) of up to 40 step(s) on headless, seed 3: 1 finding(s)
  KIND       STEPS    JOURNEY                         MESSAGE
  invariant  23 -> 2  .tca/findings/invariant-1.toml  no duplicate books (x5)
```

### `tca chaos`

```sh
tca chaos journeys/add-book.toml [--faults status500,timeout,offline,malformed,slow]
```

Runs the journey once in replay mode to learn its requests, then reruns it once per request and fault with that request failed (the Nth occurrence of a repeated request through the fault's `skip`). Launch requests are failed on a fresh launch through `TCA_HARNESS_FAULTS` (rows marked `launch`; the way forward is the first step). A rerun passes when no oracle fires and, within 5 s, the journey's next step or a retry of the failed step is offered (any operation if the journey is finished). Checks don't have to hold. Each failure becomes a journey with a `[[faults]]` entry that reproduces it. Requires protocol v3.

### Races: `tca explore --races` and `tca chaos --reorder`

```sh
tca explore --races [--latency 200 --jitter 150] ...   # don't wait while something is in flight
tca chaos journeys/discover.toml --reorder [--reorder-ms 1000]
```

`--races` dispatches the next operation while the previous one is still running (biased toward the same operation and toward dismissals) and records each such step with `no_wait = true` and `after_ms`; findings also record the replay latency. `--reorder` holds back the first of two or more same-endpoint requests made by a step or a race of `no_wait` steps, and fails when an oracle or check fires or the final state differs from the in-order run. Every runner takes `--latency MS` and `--jitter MS` (replay latency, seeded). See [Races](../docs/testing.md#races).

### `tca fixtures coverage` and `tca fixtures record`

```sh
tca fixtures coverage journeys/*.toml [--target headless] [--fixtures DIR] [--strict]
tca fixtures coverage --report explore.jsonl --report chaos.jsonl          # from earlier runs, any command
tca fixtures record journeys/*.toml --target live [--into fixtures/raw] [--sanitize fixtures/sanitize.py]
```

Every logged request says how it was answered: `exact`, `ordered` (one of several equal recordings, by occurrence), `template` (a cassette recorded for the same `match.json` path template), `path` (fallback: the latest cassette for the path, because query or body differed), `synthetic` (a `match.json` rule such as a terminal page), `fault`, `blocked` or `live`. `coverage` runs the journeys (or reads `request` events from `--report` files) and prints a row per endpoint (method and templated path) with counts per kind, the cassettes nothing used, and each request that fell back or was blocked, with the journey and step. `--strict` exits 1 if there are any; a failed journey always exits 1.

```text
fixtures coverage: 6 run(s), 0 failed; 26 request(s) to 5 endpoint(s)
  ENDPOINT        REQUESTS  EXACT  ORDERED  PATH
  GET /api/ride   6         .      .        6
  ...
fallback matches (7): no cassette for the exact request, so the latest one for its path answered. ...
  GET /api/ride?centerLongitude=13.4206...&centerLatitude=52.5289...  -> GET__api_ride_1.json  (journeys/launch.toml at launch)
```

`record` runs each journey with `--network record` on the target (respecting the app's live guard, whose name it prints; refused requests are listed and not recorded), then the `--sanitize` script once with the cassette directories as arguments, then the coverage report for the journeys replayed against their own fixtures. See [docs/testing.md](../docs/testing.md#matching-rules) for the `match.json` rules that remove fallbacks.

### `tca determinism` and `tca diff`

```sh
tca determinism journeys/add-book.toml [--runs 3] [--seed 0]
tca diff journeys/add-book.toml --targets headless,ui
```

Both capture the root state at launch and after every step and report the first step where it differs, with up to ten differing JSON paths (`shelf.books[0].id: "book-1" vs "9f2c..."`). `sessionID` and `revision` are ignored. Determinism compares fresh launches with the same seed; diff compares two targets, typically the headless host against the app in the simulator.

## Lower-level commands

```sh
tca inspect --app --port 8767 [--path root/game]
tca observe --app --port 8767
tca dispatch --app --port 8767 --candidate 'EXACT_ID' --arguments '{"value":0}'
tca wait --app --port 8767 --request-id 'RECEIPT_REQUEST_ID'
tca cancel --app --port 8767 --request-id 'RECEIPT_REQUEST_ID'
```

These take operation IDs from a current observation:

- `dispatch` supports `--revision` and `--request-id` for stale-state checks and retry identity.
- Argument objects follow each operation's schema.
- `cancel` only works if the application provides a cancellation action.
- These commands print JSON event lines.

In a checkout, leaving out `--app` builds the historical headless demo instead (see below). An installed `tca` has no demo, so it always connects to the app.

## Check an integration

```sh
tca doctor --port 8767
```

With no command, `tca` runs doctor on port 8765. Doctor always connects to the app. It never builds the headless host and never loads model credentials.

- It reports protocol and capability checks, plus runtime configuration diagnostics.
- No available operations is reported as a warning, not an error.
- A connection failure suggests the launch flags and reminds you to retain the attachment.

## Model-driven goals

`run` loops toward a goal. Each step it observes the app, asks a model to choose one offered operation (or `none`), and, if that operation has an argument schema, asks a model to fill the arguments. It stops when an app-defined predicate verifies the goal:

```sh
tca run --app --port 8767 --goal 'Start an unlimited solo game' --verify gameReady
```

Verification predicates belong to the app, not the model. The loop has these safeguards:

- A choice that wasn't offered is rejected.
- If argument generation fails or returns the wrong fields, nothing is dispatched.
- Stale revisions are re-observed rather than forced.
- Provider error bodies and credentials are never printed or written to traces.

### Providers

| `--provider` | Choosing an operation | Filling arguments | Settings |
| --- | --- | --- | --- |
| `router` | Router's `/systemone` choice classifier, which reports confidence and probability | Router's `/responses` | `RAMP_ROUTER_API_KEY`, optional `RAMP_ROUTER_BASE_URL` (default `https://api.router.com/v1`) |
| `responses` | Any OpenAI Responses API-compatible endpoint (`POST {base}/responses`). The answer is a strict JSON schema whose `choice` is an enum of the offered IDs plus `none`. Confidence and probability are `null`. | The same endpoint | `TCA_HARNESS_MODEL_API_KEY`, optional `TCA_HARNESS_MODEL_BASE_URL` (default `https://api.openai.com/v1`) |

Both providers fill arguments the same way: `text.format` is a strict `json_schema` built from the operation's argument schema.

Models:

- With `router`, the defaults are Router's classifier `jev-1.14.0` for choosing and `claude-haiku-5-5` for arguments.
- With `responses`, set `TCA_HARNESS_MODEL` (used for both calls) or pass `--model` and `--argument-model`.
- `TCA_HARNESS_MODEL` also overrides Router's argument model.
- The flags always win.

Provider selection order: `--provider`, then `TCA_HARNESS_MODEL_PROVIDER`, then the saved provider. If none is set, `router` is used when only a Router key is present, and `responses` otherwise.

### Store settings with `tca setup`

```sh
tca setup                    # prompts for provider, base URL (default shown), model, and key
printf %s "$KEY" | tca setup --provider responses --base-url https://llm.example/v1 \
  --model my-model --api-key-stdin
```

Setup handles settings and the key like this:

- The key is read with `getpass` (or from stdin with `--api-key-stdin`) and is never echoed or printed.
- Settings are written to `~/.config/tca-harness/model.env` (or `$XDG_CONFIG_HOME/tca-harness/model.env`) with mode 0600, in a 0700 directory, and the path is printed.
- Running setup for one provider keeps the other provider's saved key.
- A blank key at the interactive prompt keeps the saved key.
- Environment variables always override the file.

Keep credentials out of the repository.

## Inspect a run visually

```sh
python3 examples/isowords/run_goals.py > /tmp/run.jsonl
tca trace --input /tmp/run.jsonl --output /tmp/run.html
```

Open the generated file in a modern browser. It works offline, needs no app connection or model credentials, and has no JavaScript dependencies. A [saved isowords run](../examples/isowords/recordings/interpretable-run.html) is included.

Select a goal, then an event, to inspect:

- the instruction and offered operations
- the provider-reported confidence (empty for the `responses` provider)
- generated arguments and the execution receipt
- observed state differences and verification evidence

Pacing and mechanical gesture releases are hidden from the event list at first and can be expanded. The timing chart separates choice calls, argument generation, dispatch, waits, and configured pacing. A passed goal and an individual receipt status are shown separately.

Events and their contents:

- New events have a schema version, sequence number, wall-clock timestamp, and monotonic `tMs`.
- Model-driven runs record the projected observation used for each decision, plus `model`, `provider`, and `latencyMs`.
- Dispatch events record arguments and the returned observation.
- The isowords suite also records predicate checks, readiness waits, and pacing.
- These files contain projected app state.

Older JSONL traces still open. They show event order rather than invented timestamps, and they say when snapshots or alternatives are missing. Goal-end summaries are not treated as full state snapshots.

State differences describe observations, not proof that an action caused them; async changes can appear in a later snapshot. The viewer does not invent model reasoning, explanations for unavailable actions, video synchronization, or timing for work that wasn't instrumented.

## Watch actions live

```sh
tca devtools --port 8767 [--http-port 8780]
```

This serves a panel on `http://127.0.0.1:8780` that polls the app's timeline through the harness connection. The app must apply `.harnessTimeline()` to its root reducer; see the [package guide](../TCAHarnessTCA1/README.md#record-a-timeline-for-devtools) for privacy and cost.

The server binds to loopback and rejects requests whose `Host` is not `127.0.0.1` or `localhost`, so other web pages can't read app state through it.

- **Log**: every reduced action, newest first, tagged `agent` or `effect` when the app didn't send it. A dot marks a state change, and running or cancelled effects are labelled. Filter by source or by action name.
- **State**: the state after the action as the descriptor observes it, with changed branches expanded and marked. Truncated snapshots are flagged.
- **Action**: case path, payload (structure only in the default projected detail), source, the agent operation ID, reducer time, and recorder cost.
- **Diff**: each changed path with its previous and new value.
- **Effects**: whether the action returned an effect, when it ended, which action's effect sent it, and the actions it has sent so far.
- **Mounts**: features and agent operations available after the action, with additions and removals.

Clicking a row, scrubbing, or pressing ↑/↓ (`j`/`k`) pauses on an action. Esc or Resume returns to live. **Export JSON** saves the retained entries. Relaunching the app starts a new timeline, and the panel follows it.

## Client checks

```sh
python3 -m unittest discover -s cli/tests
```

These tests need no app, model credentials, network, or Swift build. They cover:

- read-only doctor and protocol diagnosis
- `ls`/`do` against a fake host
- check expressions, including refused inputs, and the TOML writer
- targets, journeys, recording, explore and shrinking, chaos, determinism and diff end to end against [a fake protocol v3 app](tests/fake_app.py) with planted bugs
- request patterns and per-step expectations, launch faults (journeys and chaos), fixture coverage and the recording sweep
- both providers against a mocked network
- `setup`
- the devtools relay and connection failures

The devtools panel checks drive `devtools.html` against a recorded isowords timeline in jsdom. They run when Node can `require("jsdom")` and are skipped otherwise. To enable them, run `npm install jsdom` in a scratch directory and set `NODE_PATH` to its `node_modules`.

## TCA 2 task experiment

In a checkout, running without `--app` builds and launches the historical headless task host in `prototypes/tca-harness`. That demo requires private TCA 2 access, XcodeGen, and FlowDeck. You don't need it to use the CLI against an existing app.

Task-specific demo commands are documented in [the prototype guide](../prototypes/tca-harness/README.md). The isowords scripts load `cli/tca.py` directly and don't need the task host or TCA 2. They pin Router model IDs, so run them with Router credentials.
