# Testing with the harness

Tests here describe what a user does and sees, not how the code is built. A test names a goal, the steps a user takes (by their labels), and what must be true afterwards in the published state. Internals can be rewritten freely; a test only breaks when the user-visible behavior does.

The same test runs at three rungs:

| Rung | Target | Network | Speed | For |
| --- | --- | --- | --- | --- |
| 1 | Headless host | Replayed fixtures, everything else blocked | ~70 actions/s, a fresh process per run | The agent's inner loop, exploration, fault injection |
| 2 | App in the simulator | Replayed fixtures, everything else blocked | Simulator speed, with screenshots and video | View-owned behavior, evidence for a PR |
| 3 | App or headless host | Live backend | Backend latency | Contract drift, timing; refreshes the fixtures for rungs 1 and 2 |

## Patterns and the bugs they catch

| Pattern | Command | Catches | Rungs |
| --- | --- | --- | --- |
| **Journey** | `tca journey run` | A flow a user relies on no longer reaches its outcome | 1, 2, 3 |
| **Network discipline** | any run with `network = "replay"` | Requests nobody expected: chatty analytics, refetch loops, real traffic leaking from a test | 1, 2 |
| **Screen contract** | step `requests = [...]` in a journey | A screen that stopped making (or started making) a call: a missing refetch, a duplicate request, a new endpoint | 1, 2, 3 |
| **Fixture coverage** | `tca fixtures coverage` | Replays that only pass by accident: requests answered by a fallback cassette, cassettes nothing uses | 1 |
| **Fault injection** | `tca chaos` | Errors that strand the user: stuck spinners, swallowed failures, crashes on bad responses | 1 |
| **Invariants** | always on | State that contradicts itself: a badge that disagrees with the list, duplicate rows | 1, 2, 3 |
| **Exploration** | `tca explore` | Sequences nobody wrote a test for: effects that outlive their screen, invalid input, states nobody planned. Shrinks each finding to a minimal journey | 1 |
| **Races** | `tca explore --races`, `tca chaos --reorder` | Timing a person produces and a waiting test never does: double taps while a request is in flight, dismissing or going back mid-request, a stale response overwriting a newer one, out-of-order responses | 1 |
| **Determinism** | `tca determinism` | Hidden nondeterminism: direct `Date()`, `UUID()`, unseeded randomness, order dependence | 1 |
| **Rung differential** | `tca diff` | Logic that only runs when views exist (`.onAppear` side effects), lifecycle-dependent behavior | 1 vs 2 |
| **Contract check** | `tca journey run --network record` | The backend changed shape: renamed fields, new required values, decode failures | 3 |

Every run also applies the generic oracles below, so even a journey with no checks catches crashes and errors.

### Generic oracles

A run fails, and records a finding, when any of these happen:

- **crash**: the target process exits or the connection drops.
- **issue**: the app reported a runtime issue (`reportIssue`, TCA runtime warnings such as an action sent to a dismissed child, `unimplemented` dependencies).
- **invariant**: an invariant declared on a descriptor became false.
- **network**: a request had no fixture in `replay`, or was attempted in `block`.
- **stuck**: a receipt is still `running` after the wait budget (default 5 s).
- **rejected**: an operation that was offered was then rejected for a reason other than a stale revision.
- **dead end**: nothing is offered and the journey didn't declare the state terminal.

The oracles run after every step, and once more after the last step when the app has gone quiet: no state change, request or issue for 300 ms (at most 2 s), and no request in flight (at most the stuck budget, `--wait-ms`). A real app keeps running after the user's last tap, so effects that land late, like a response delivered to a screen that already closed, still count. Request budgets include those late requests. Runs also wait for the same quiet before the first step, so launch fetches that answer after the listener is up (even slow ones) land before step 1, as they would before a person's first tap.

Journeys can also fail with these kinds, which are about the journey rather than the app's health: **step** (a step didn't resolve or finished `failed`), **expect** and **check** (an expression didn't hold), **budget** (too many requests), **requests** (a step made different requests than it declares, below) and **faults** (the journey's faults couldn't be applied).

## Journeys

A journey is a TOML file. Steps name operations the way a user sees them: by label or operation name, resolved like `tca do`.

```toml
name = "Add a book"
goal = "Add a book called Dune and see it on the shelf"
fixtures = "fixtures/shelf"          # cassette directory, relative to this file
network = "replay"                   # block | replay | record | live

[[steps]]
do = "Add book"

[[steps]]
do = "Set title"
args = { value = "Dune" }

[[steps]]
do = "Save"
expect = "not editor"                # optional check after this step

[checks]                             # all must hold at the end
"Dune is on the shelf" = "any(b.title == 'Dune' for b in shelf.books)"
"nothing is loading" = "not shelf.isLoading"

[budget]
requests = 3                         # optional: fail if the journey makes more requests
```

Checks are expressions over the published state of the root feature, using attribute access on objects (`shelf.books`), indexing, comparisons, `and`/`or`/`not`, arithmetic, generator expressions and `len`, `any`, `all`, `sum`, `min`, `max`, `sorted`, `set`. Nothing else is allowed. Missing keys evaluate to `None` rather than raising, so `not editor` works when the editor is closed. `expect` and `[checks]` are re-evaluated against fresh observations for up to 1 s while effects settle.

Optional keys:

| Key | Meaning |
| --- | --- |
| `seed = 3` | `TCA_HARNESS_SEED` for this journey (default 0; `--seed` overrides). Findings record the seed they were found with. |
| `terminal = true` | The end state may offer nothing; otherwise an empty end state is a **dead end**. |
| `[[faults]]` | Faults (the wire format below) set through `network` before the first step. Chaos findings use this to reproduce. |
| fault `at = "launch"` | Pass this fault to the launch in `TCA_HARNESS_FAULTS` instead, so it reaches requests the app makes before the CLI connects. Needs a fresh launch per run (`restart = "per-run"`). |
| step `path = "root/shelf"` | Resolve the step against this feature, like `tca do --path`. |
| step `args = '{"note": null}'` | Arguments as a JSON string, for values TOML can't express (`null`). |
| step `requests = ["GET /books"]` | The requests this step makes (below). `[]` means none. |
| step `no_wait = true` | Dispatch this step without waiting for the previous one to finish: its receipt, its `expect` and the quiet after it. The previous step's `expect`/`requests` aren't allowed; a race's requests are checked on its last step ([Races](#races)). |
| step `after_ms = 150` | Pause before dispatching: measured from the previous step's dispatch with `no_wait`, else from when it finished. |
| `latency = { ms = 200, jitter_ms = 150 }` | Replay latency for this journey (`TCA_HARNESS_LATENCY`; `--latency`/`--jitter` override it). Also `seed` and `paths = { "/search" = { ms = 600 } }`, or a plain number of milliseconds ([Races](#races)). |
| `launch_requests = ["GET /books"]` | The requests the app makes at launch, before the first step. Put it above the first `[[steps]]`/`[[faults]]` table. |

### Screen contracts: the requests each step makes

In a server-driven app most screens are defined by the calls they make. A step can pin them:

```toml
launch_requests = ["GET /books"]

[[steps]]
do = "Search"
args = { value = "Weir" }
requests = ["POST /events"]          # one analytics event per search, not per keystroke

[[steps]]
do = "Open book"
requests = []                        # opening a book is local

[[steps]]
do = "Mark as read"
requests = ["PUT /books/{id}"]
```

The requests of a step are the ones the app logs between its dispatch and the next step, after the app goes quiet (so a journey that declares any `requests` waits for quiet after every step). They're compared as a multiset, in any order. A pattern is `METHOD /path`: `{name}` matches one path segment, `*` matches anything (`GET /books/*`), and the method can be `*`. A pattern without `?` ignores the query; with one it matches the query too (`GET /books?page=*`, or `GET /books?*` for "any query"). On a mismatch the run fails with a **requests** finding that lists both sides. The journey still runs to the end, so the other steps' requests, the oracles and the checks are reported too:

```text
FAIL  Search the shelf  (journeys/search.toml)
  requests after step 1 "Search": expected [POST /events], made [POST /events, POST /events, POST /events] (unexpected POST /events, POST /events)
```

Requests are checked on every rung, and skipped by chaos (a faulted run makes retries) and against apps without the `network` method. `tca record` writes them for you (below), so an agent that solves a journey also pins what each screen asked the server for.

A journey can omit `steps` and give only a `goal`: an agent solves it once with `tca ls`/`tca do` while `tca record` captures the steps, and the solved steps are written back. When a step stops resolving (a label changed, a screen moved), `tca journey run` fails with the current view and the remaining goal, and an agent re-solves it the same way. Nobody maintains step scripts by hand.

### Recording a journey from an agent session

```sh
tca record start journeys/add-book.toml --goal "Add a book called Dune and see it on the shelf"
tca do "Add book" --port 8790
tca do "Set title" '{"value":"Dune"}' --port 8790
tca do Save --port 8790
tca record stop --check "Dune is on the shelf=any(b.title == 'Dune' for b in shelf.books)"
```

While a recording is active (`.tca/recording.json` in the current directory), each successful `tca do` appends its step by label, and the requests the app logged until the next `tca do` (or `tca record stop`, which waits for quiet) become that step's `requests`, as `METHOD /path` with ids templated: the `match.json` template when one matched, otherwise numeric, UUID and long hex segments become `{id}`. Requests logged before the first step become `launch_requests`, so record on a fresh launch. A step that made none gets `requests = []`. Against an app without the `network` method, steps get no `requests`.

### When a flow changes: re-solving

A journey breaks when what the user sees changes, not when code moves. Here the Shelf button's label was changed from "Add book" to "New book", as a copy change would. The run fails at the step that no longer resolves and prints what an agent needs to fix it:

```text
FAIL  Add a book  (journeys/add-book.toml)
  step 1 "Add book": no offered operation matches
  current view:
    …
    From root:
      add  - New book
      refresh  - Refresh
      …
  goal: Add Dune by Frank Herbert and see it on the shelf, unread
  remaining steps: "Add book", "Set title", "Set author", "Save"
  hint: re-solve it: `tca record start journeys/add-book.toml`, reach the goal with `tca ls`/`tca do`, then `tca record stop`
```

An agent re-solves it against a running app, without editing the file:

```sh
tca record start journeys/add-book.toml
tca do "New book" --port 8796
tca do "Set title" '{"value":"Dune"}' --port 8796
tca do "Set author" '{"value":"Frank Herbert"}' --port 8796
tca do Save --port 8796
tca record stop
```

Only the steps change. The goal, checks, budget, fixtures and comments are kept as written, and each step now pins the requests it made:

```diff
+launch_requests = ["GET /books"]

 [[steps]]
-do = "Add book"
+do = "New book"
+requests = []
 …
 [[steps]]
 do = "Save"
+requests = ["POST /books", "POST /events"]
```

If the user-visible outcome can no longer be reached, the checks fail instead, and that's a real regression. Adding `--check` to `record stop` rewrites the whole file.

## Targets

`harness.toml` at the project root says how to launch each rung. The CLI starts a fresh process for every run so runs never share state.

```toml
[targets.headless]
launch = ".build/debug/shelf-headless --port {port}"
port = "auto"                        # pick a free port
ready = "TCA harness listening"      # line on stderr that means ready
restart = "per-run"                  # per-run | never
ready_timeout = 30                   # seconds (default 30)

[targets.ui]
launch = "flowdeck run --no-build --launch-env 'TCA_HARNESS=1 TCA_HARNESS_PORT={port} {env}'"
port = 8792
restart = "per-run"
ready_timeout = 90

[targets.live]
launch = ".build/debug/shelf-headless --port {port}"
port = "auto"
env = { SHELF_API = "http://127.0.0.1:8799" }
```

The command runs through the shell from the directory holding `harness.toml`, in its own process group, which is killed when the run ends. Its merged stdout and stderr go into `--report`, and their tail is shown when it crashes. Without `ready`, the CLI polls the port. `restart = "never"` reuses one process for every run of a command (or an app already listening on a fixed port), switching its network mode through `network`. An optional `stop` command runs after each process is stopped, for launchers such as `flowdeck run` that exit while the app keeps running. A launcher that exits after the app is ready is not a crash; only a dropped connection is.

`harness.toml` is found by searching upward from the journey file, then from the current directory. `tca journey run --port N` attaches to an app that is already running instead of launching one; runs then share its state.

The CLI passes the run's settings as environment variables, appended to `{env}` for launch commands that can't inherit the environment:

| Variable | Meaning |
| --- | --- |
| `TCA_HARNESS_NETWORK` | `block`, `replay`, `record` or `live` |
| `TCA_HARNESS_CASSETTES` | Absolute cassette directory |
| `TCA_HARNESS_SEED` | Seed for deterministic dependencies (integer) |
| `TCA_HARNESS_PORT` | Port to listen on |
| `TCA_HARNESS_FAULTS` | Faults pending from the first request, as compact JSON (the journey's `at = "launch"` faults, or chaos on a launch request). Set only when there are some. In `{env}` it contains double quotes, so a launch command that wraps `{env}` in double quotes can't take it |
| `TCA_HARNESS_LATENCY` | Replay latency, as compact JSON (`{"jitter_ms":150,"ms":200}`) or milliseconds. Set only when the run has one. Same quoting caveat |

## Commands

```text
tca journey run FILE... [--target headless] [--network MODE] [--seed N] [--report out.jsonl] [--port N]
tca record start FILE --goal TEXT | tca record stop [--check NAME=EXPR]...
tca explore [--target headless] [--runs 50] [--steps 40] [--seed N] [--journey FILE]  # FILE: start from its end state
            [--fixtures DIR] [--network MODE] [--shrink-trials 100] [--races]
tca chaos FILE [--target headless] [--faults status500,timeout,offline,malformed,slow]
tca chaos FILE --reorder [--reorder-ms 1000]
tca determinism FILE [--target headless] [--runs 3]
tca diff FILE --targets headless,ui
tca fixtures coverage [FILE...] [--target headless] [--fixtures DIR] [--report run.jsonl]... [--strict]
tca fixtures record FILE... --target live [--into DIR] [--sanitize SCRIPT] [--strict] [--no-coverage]
tca exposure [--port N | --target T] [--journeys GLOB...] [--reports FILE...] [--json] [--min-exercised PCT]
```

All commands print a short plain-text summary, write JSON lines with `--report` (the `tca trace` format), and exit 1 when they found something, 2 for usage or configuration errors. All take `--wait-ms` (the stuck budget, default 5000), `--seed`, and `--latency MS`/`--jitter MS` (replay latency, [Races](#races)); finding commands take `--out DIR`. Each finding is written as a minimal journey under `.tca/findings/` that reproduces it with `tca journey run` (determinism and diff findings reproduce with the command that found them). Against a protocol v2 app the issue, invariant and network oracles are skipped, and the summary says so once.

- **explore** walks random offered operations, generating arguments from each operation's schema (strings from a small corpus that includes empty, long and unicode values). After a finding it relaunches and shrinks the step list (delta debugging) to the shortest sequence that still produces the same finding kind.
- **explore --races** and **chaos --reorder**: see [Races](#races).
- **chaos** first runs the journey in replay mode to learn which requests it makes. Then, for each request and each fault, it reruns the journey with that one request failed. A run passes when no generic oracle fires and, within 5 s of the fault, the app still offers a way forward: the journey's next step, a retry of the step whose request failed, or any operation if the journey is finished. Otherwise the finding is **stranded**. Checks are not required to hold, and the failed step's receipt may be `failed`. To fail the Nth occurrence of a request, the fault is set before the first step with `skip = N-1`. Requests made during launch (before the first step) are faulted the same way through `TCA_HARNESS_FAULTS` on a fresh launch (`at = "launch"`, rows marked `launch`); the way forward is then the journey's first step. With `--port` or `restart = "never"` they can't be, and are listed in a note.
- **determinism** runs the journey several times from fresh launches with the same seed and compares the published state after every step; it reports the first step where runs differ and the differing paths.
- **diff** runs the journey on two targets and compares published state after every step, reporting the first difference.
- **fixtures coverage** runs the journeys in their own network mode (replay) on fresh launches, or reads the `request` events of earlier `--report` files (from any command), and prints, per endpoint (method and templated path), how many requests were answered each way (`match`, below). Then the cassettes no request was answered with, and the requests that only matched by fallback (`path`) or were blocked, each with where it happened. `--strict` exits 1 when there are any of those. A failed journey exits 1 too.
- **exposure** reports, per feature path, the operations the descriptor declares with how many dispatches ran each, and the action cases no operation sends, from a live app (`--port`/`--target`), journey runs (`--journeys`) and earlier reports (`--reports`). Features in the descriptor's catalog that no run mounted are listed as not reached. `--min-exercised PCT` fails below that share. Reports from every command carry a `catalog` event and `mounts` events for this. See [the command reference](../cli/README.md#tca-exposure).
- **fixtures record** runs each journey with `--network record` on the given target (cassettes go to the journey's `fixtures`, or `--into DIR`), prints what was written, what the live guard refused, and the guard's name (with a note when the app sets none). Then it runs `--sanitize` once (a `.py` file runs with this Python; the cassette directories are its arguments and the first is in `TCA_HARNESS_CASSETTES`), and replays the journeys for the coverage report (`--no-coverage` skips it). Each journey records in its own process, so recordings of the same endpoint by different journeys share a name and the last one wins.

```text
fixtures coverage: 6 run(s), 0 failed; 26 request(s) to 5 endpoint(s)
  ENDPOINT                                REQUESTS  EXACT  ORDERED  SYNTHETIC
  GET /api/ride                           6         6      .        .
  GET /api/v1/timelines/tag/CriticalMass  4         3      .        1
  GET /locations                          6         6      .        .
  GET /messages                           9         .      9        .
  POST /messages                          1         1      .        .
cassettes in fixtures/criticalmaps: 8 of 9 used
  unused: PUT__locations_1.json
```

## Races

Most bugs in a server-driven app are about timing: a second tap on Save while the first POST is in flight, closing a sheet before its request answers, a slow response to an old search landing after the new one. A journey that waits for every receipt and a replay that answers in a millisecond never produce that timing. Three pieces do:

**Replay latency.** Replayed responses can take time, so requests are really in flight while the run goes on. Set it per run (`--latency 200 --jitter 150`), per journey (`latency = { ms = 200, jitter_ms = 150 }`), or with the fixtures, in `match.json`:

```json
{"latency": {"ms": 200, "jitter_ms": 150, "paths": {"/catalog": {"ms": 600}, "/events": {"ms": 0}}}}
```

Each replayed request waits `ms` plus a jitter drawn uniformly from `-jitter_ms...jitter_ms` (never below zero). The jitter is a function of the seed (`seed`, default `TCA_HARNESS_SEED`), the method and path, and the request's occurrence among requests with that method and path, so a run waits the same on every replay. A `paths` rule (a path or a pattern with `{name}`/`*` segments) replaces `ms`, and `jitter_ms` if it gives one. The run's latency (`--latency`, the journey's, `TCA_HARNESS_LATENCY`, or the `network` method) replaces `match.json`'s. Latency applies in `replay` only, to fixtures and faults alike (a `delay` fault adds to it). `record` and `live` have the server's own.

**Races in journeys.** `no_wait = true` on a step dispatches it without waiting for the previous one; `after_ms` sets the gap from the previous dispatch. A step followed by `no_wait` steps is a race: its receipt is settled when the race's last step has finished (a receipt still running past the stuck budget, counted from its own dispatch, is **stuck**; a raced receipt that ends `failed` or `cancelled` is not a finding, since a raced tap often loses), its requests are checked against the `requests` of the race's last step, and an empty view in the middle of a race is the request in flight, not a dead end. Every oracle still runs after each step and once the app has gone quiet.

```toml
[[steps]]
do = "Save"

[[steps]]
do = "Save"          # a double tap: 60 ms after the first, while its POST is in flight
no_wait = true
after_ms = 60
```

**`tca explore --races`** walks like `explore`, but dispatches without waiting. When a step leaves something in flight (its receipt is running, or the app reports `pending` requests), the next operation usually (60%) goes right away or after a short gap (0 to 400 ms), and is biased toward the same operation again (a double tap, with the same arguments half the time), toward a dismissal (an operation labelled Close, Cancel, Done, Back, Dismiss...) and toward a sibling on the same screen. Otherwise it waits for the step to finish, as a person who waits would. Every step taken is recorded with its `no_wait` and `after_ms`, and the finding's journey records the latency and seed, so `tca journey run` replays the race, not just the steps. Shrinking keeps each step's timing (a step whose predecessor was removed races the one before), retries each candidate once more because timing can vary, and the first step of a shrunk journey always waits for launch. Then it drops each `no_wait`/`after_ms` the finding doesn't need: a finding that keeps one is a race, and one that keeps none says so in its header ("It needs no race"), which is the first triage question. Without a latency from `--latency`, the journey or `match.json`, `--races` uses 200 ms +/- 150 ms and says so.

```text
$ SHELF_BUGS=double-save tca explore --races --fixtures fixtures/shelf --runs 30 --steps 30
explore: 30 run(s) of up to 30 step(s) on headless, seed 0, races, latency 200 ms +/- 150 ms: 1 finding(s)
  KIND       STEPS    JOURNEY                         MESSAGE
  invariant  25 -> 4  .tca/findings/invariant-1.toml  root: no duplicate books (x5)
```

**`tca chaos FILE --reorder`** finds the steps, and races, that make two or more requests to the same endpoint (method and path) in an in-order run, holds the first of them back (`--reorder-ms`, default 1000, a `delay` fault with `skip`) so the responses arrive out of order, and reruns the journey. A run fails when an oracle or check fires, or when the final state, once the app is quiet, differs from the in-order run's (**stale**: a stale response won). A run whose held response still came first is reported as `not reordered`. Findings are journeys with the `delay` fault; a **stale** finding reproduces with `tca chaos --reorder` (it needs the in-order run to compare against). Two searches typed fast are a race of two steps:

```text
$ SHELF_BUGS=stale-search tca chaos --reorder journeys/discover.toml
chaos --reorder: Find a book, typing fast: 1 request(s) held back, 1 failure(s)
  STEP  REQUEST       FAULT         RESULT
  2-3   GET /catalog  held 1000 ms  FAIL invariant after step 3 "Search catalog": root: catalog results are for the search field
```

A race finding is only as good as the replayed timing. Before treating one as an app bug, check that a person could produce the same interleaving: that the operations raced are offered at once in the UI (an operation the view disables but the descriptor offers is a descriptor gap, not a race), and that the latency is plausible for the endpoint.

## Wire protocol additions (protocol version 3)

Two methods are added, and every observation gains `issueCount`.

```text
→ {"method":"issues","since":0}
← {"ok":true,"issues":[{"seq":1,"kind":"issue","message":"...","file":"Shelf.swift","line":42,"action":"shelf.deleteResponse"}],
   "observation":{...}}
```

`kind` is `issue`, `invariant` or `network`. `action` is the most recent reduced action, when the timeline recorder is attached.

```text
→ {"method":"network"}                                   # read
→ {"method":"network","network":{"mode":"replay","faults":[...]}}   # change, then read
← {"ok":true,"network":{"mode":"replay","cassettes":"/abs/dir",
   "requests":[{"seq":1,"method":"POST","url":"http://api/books","status":201,"source":"fixture","fault":null,"ms":3,
                "match":"exact","cassette":"POST__books_1.json"}],
   "faults":[...],"pending":0},"observation":{...}}
```

A fault is `{"match":{"method":"POST","path":"/books"},"kind":"status","status":500,"times":1}`. `kind` is `status` (with `status`), `timeout`, `offline`, `malformed` (200 with invalid JSON body) or `delay` (with `delayMs`, then the normal response). `match` fields are optional; `skip` (default 0) lets that many matching requests through before the fault applies; `times` defaults to 1, `-1` means always. Skipped requests don't count toward `times`. `source` is `fixture`, `live`, `fault` or `blocked`. `match` says how the request was answered: `exact` (a cassette with the same method, path, query and body, after the matching rules' ignores), `ordered` (one of several equal recordings, picked by occurrence), `template` (no cassette for this path; one for the same path template), `path` (fallback: the latest cassette for the method and path or template, because query or body differed), `synthetic` (a matching rule answered, e.g. a terminal page), `fault`, `blocked` or `live`. `cassette` is the file that answered (or, in `record`, was written) and `template` the path template that matched, each only when there is one. `pending` counts requests started but not answered yet; requests are logged when they finish. The `network` object may set `latency` (the replay latency, the `match.json` form); the snapshot shows the latency in effect, the run's or `match.json`'s, as `latency`. These fields were added without a protocol version change; clients ignore what they don't know. A `status` fault responds with an empty body; `timeout` and `offline` fail with `URLError.timedOut` and `URLError.notConnectedToInternet`. Exhausted faults disappear from `faults`. The `network` object may also set `cassettes` (a directory path), and `since` limits `requests` to entries after that `seq`. When the app set a live guard (below), the snapshot includes its name as `liveGuard`; the `network` method can't change or remove it.

## Matching rules

A cassette directory can hold `match.json`, read on every request (edits apply to the next request):

```json
{
  "ignore_query": ["t"],
  "path_templates": ["/books/{id}", "/rides/{id}/attendees"],
  "paths": {
    "/events": {"ignore_body": true},
    "/api/ride": {"ignore_query": ["centerLatitude", "centerLongitude"]}
  },
  "pagination": [
    {"path": "/api/v1/timelines/tag/{tag}", "cursor": "max_id", "terminal": {"status": 200, "body": []}}
  ]
}
```

| Key | Effect |
| --- | --- |
| `ignore_query` | Query parameters left out when comparing a request with a cassette, for every path: cache busters, timestamps, coordinates with noise. |
| `paths` | Rules for a path pattern: `ignore_query` (added to the global list) and `ignore_body: true` (only method, path and query must match: analytics, acknowledgements). Every matching pattern applies. |
| `path_templates` | When no cassette has the request's exact path, cassettes whose path fits the same template answer (`/users/456` from a recording of `/users/123`). Logged as `template`. Recording names files after the template. |
| `latency` | Replay latency for these cassettes: `{"ms": 200, "jitter_ms": 150, "paths": {"/search": {"ms": 600}}}` ([Races](#races)). A run's own latency replaces it. |
| `pagination` | For a request to `path` that carries a non-empty `cursor` parameter (a name or a list) and has no matching cassette: serve `terminal` (default status 200, body `[]`) instead of falling back to the latest page, so a feed ends instead of repeating its last page. Logged as `synthetic`. The first page (no cursor) still falls back normally. |

Path patterns are literal paths in which a `{name}` or `*` segment matches any one segment. A `match.json` that doesn't parse is reported once as a `network` issue and ignored. `tca fixtures coverage` shows what the rules bought: requests that were `path` fallbacks become `exact`, `template` or `synthetic`.

## Swift API

```swift
// Invariants live next to the feature, on its descriptor. Children are prefixed with their path.
Shelf.harnessDescriptor
  .invariant("unread badge matches the list") { $0.unreadCount == $0.books.filter { !$0.isRead }.count }
  .invariant("no duplicate books") { Set($0.books.map(\.id)).count == $0.books.count }

// Network: route URLSession traffic through the harness. Reads TCA_HARNESS_NETWORK, TCA_HARNESS_CASSETTES
// and TCA_HARNESS_FAULTS (faults pending from the first request, so launch requests can be failed).
HarnessNetwork.install()                                   // URLSession.shared
let session = URLSession(configuration: HarnessNetwork.configure(.ephemeral))   // custom sessions

// Recording from a production service: in `record` and `live`, only GET/HEAD to these hosts leave the
// process. Everything else fails like `block` and is reported as a `network` issue.
HarnessNetwork.shared.liveGuard = .readOnly(hosts: ["api.example.com"])

// Replay latency, if the run doesn't set one (TCA_HARNESS_LATENCY) and match.json has none.
HarnessNetwork.shared.latency = HarnessLatency(ms: 200, jitterMs: 150)

// Deterministic dependencies for runs that ask for them (TCA_HARNESS_SEED set).
let store = Store(initialState: App.State()) { App().harnessTimeline() } withDependencies: {
  $0.harnessDeterministic()       // uuid: incrementing, date: fixed start, random: seeded. No-op without a seed.
}
```

`@HarnessFeature` users add invariants in `static func customizeHarnessDescriptor(_:)` (marked `@MainActor`), which the generated descriptor passes through. Root invariants are named `root: <name>`, children `<path>: <name>`, with identified and stack elements including their id (`root/items/3: <name>`).

Issues are captured automatically while a harness attachment exists: the attachment installs an `IssueReporter` that records every reported issue, and keeps the default reporters so Xcode still shows them.

Cassettes are one JSON file per recorded exchange, named `<METHOD>_<path with / as _>_<n>.json`, holding `{request: {method, url, body}, response: {status, headers, body}}`. Matching is by method and path, then by query and body, falling back to the latest recording for that method and path. Recordings that match equally are served in order of `n`, repeating the last. In `record` mode `n` counts this run's requests with the same method and path from 1, so re-recording replaces old files. A path that fits a `path_templates` entry (below) is named after the template, e.g. `PUT__books_{id}_1.json`, so recordings for different ids share one name and count. A body is stored as its JSON value when it is JSON, as a string otherwise, `null` when empty, and as base64 in `bodyBase64` when it is not UTF-8. Fixtures are plain files so an agent or a person can edit them. Interception, issue capture and the seed are compiled only into `DEBUG` builds, like the listener.
