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
| **Exploration** | `tca explore` | Sequences nobody wrote a test for: double taps, dismissing mid-request, effects that outlive their screen. Shrinks each finding to a minimal journey | 1 |
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

## Commands

```text
tca journey run FILE... [--target headless] [--network MODE] [--seed N] [--report out.jsonl] [--port N]
tca record start FILE --goal TEXT | tca record stop [--check NAME=EXPR]...
tca explore [--target headless] [--runs 50] [--steps 40] [--seed N] [--journey FILE]  # FILE: start from its end state
            [--fixtures DIR] [--network MODE] [--shrink-trials 100]
tca chaos FILE [--target headless] [--faults status500,timeout,offline,malformed,slow]
tca determinism FILE [--target headless] [--runs 3]
tca diff FILE --targets headless,ui
tca fixtures coverage [FILE...] [--target headless] [--fixtures DIR] [--report run.jsonl]... [--strict]
tca fixtures record FILE... --target live [--into DIR] [--sanitize SCRIPT] [--strict] [--no-coverage]
```

All commands print a short plain-text summary, write JSON lines with `--report` (the `tca trace` format), and exit 1 when they found something, 2 for usage or configuration errors. All take `--wait-ms` (the stuck budget, default 5000) and `--seed`; finding commands take `--out DIR`. Each finding is written as a minimal journey under `.tca/findings/` that reproduces it with `tca journey run` (determinism and diff findings reproduce with the command that found them). Against a protocol v2 app the issue, invariant and network oracles are skipped, and the summary says so once.

- **explore** walks random offered operations, generating arguments from each operation's schema (strings from a small corpus that includes empty, long and unicode values). After a finding it relaunches and shrinks the step list (delta debugging) to the shortest sequence that still produces the same finding kind.
- **chaos** first runs the journey in replay mode to learn which requests it makes. Then, for each request and each fault, it reruns the journey with that one request failed. A run passes when no generic oracle fires and, within 5 s of the fault, the app still offers a way forward: the journey's next step, a retry of the step whose request failed, or any operation if the journey is finished. Otherwise the finding is **stranded**. Checks are not required to hold, and the failed step's receipt may be `failed`. To fail the Nth occurrence of a request, the fault is set before the first step with `skip = N-1`. Requests made during launch (before the first step) are faulted the same way through `TCA_HARNESS_FAULTS` on a fresh launch (`at = "launch"`, rows marked `launch`); the way forward is then the journey's first step. With `--port` or `restart = "never"` they can't be, and are listed in a note.
- **determinism** runs the journey several times from fresh launches with the same seed and compares the published state after every step; it reports the first step where runs differ and the differing paths.
- **diff** runs the journey on two targets and compares published state after every step, reporting the first difference.
- **fixtures coverage** runs the journeys in their own network mode (replay) on fresh launches, or reads the `request` events of earlier `--report` files (from any command), and prints, per endpoint (method and templated path), how many requests were answered each way (`match`, below). Then the cassettes no request was answered with, and the requests that only matched by fallback (`path`) or were blocked, each with where it happened. `--strict` exits 1 when there are any of those. A failed journey exits 1 too.
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

A fault is `{"match":{"method":"POST","path":"/books"},"kind":"status","status":500,"times":1}`. `kind` is `status` (with `status`), `timeout`, `offline`, `malformed` (200 with invalid JSON body) or `delay` (with `delayMs`, then the normal response). `match` fields are optional; `skip` (default 0) lets that many matching requests through before the fault applies; `times` defaults to 1, `-1` means always. Skipped requests don't count toward `times`. `source` is `fixture`, `live`, `fault` or `blocked`. `match` says how the request was answered: `exact` (a cassette with the same method, path, query and body, after the matching rules' ignores), `ordered` (one of several equal recordings, picked by occurrence), `template` (no cassette for this path; one for the same path template), `path` (fallback: the latest cassette for the method and path or template, because query or body differed), `synthetic` (a matching rule answered, e.g. a terminal page), `fault`, `blocked` or `live`. `cassette` is the file that answered (or, in `record`, was written) and `template` the path template that matched, each only when there is one. `pending` counts requests started but not answered yet; requests are logged when they finish. These fields were added without a protocol version change; clients ignore what they don't know. A `status` fault responds with an empty body; `timeout` and `offline` fail with `URLError.timedOut` and `URLError.notConnectedToInternet`. Exhausted faults disappear from `faults`. The `network` object may also set `cassettes` (a directory path), and `since` limits `requests` to entries after that `seq`. When the app set a live guard (below), the snapshot includes its name as `liveGuard`; the `network` method can't change or remove it.

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

// Deterministic dependencies for runs that ask for them (TCA_HARNESS_SEED set).
let store = Store(initialState: App.State()) { App().harnessTimeline() } withDependencies: {
  $0.harnessDeterministic()       // uuid: incrementing, date: fixed start, random: seeded. No-op without a seed.
}
```

`@HarnessFeature` users add invariants in `static func customizeHarnessDescriptor(_:)` (marked `@MainActor`), which the generated descriptor passes through. Root invariants are named `root: <name>`, children `<path>: <name>`, with identified and stack elements including their id (`root/items/3: <name>`).

Issues are captured automatically while a harness attachment exists: the attachment installs an `IssueReporter` that records every reported issue, and keeps the default reporters so Xcode still shows them.

Cassettes are one JSON file per recorded exchange, named `<METHOD>_<path with / as _>_<n>.json`, holding `{request: {method, url, body}, response: {status, headers, body}}`. Matching is by method and path, then by query and body, falling back to the latest recording for that method and path. Recordings that match equally are served in order of `n`, repeating the last. In `record` mode `n` counts this run's requests with the same method and path from 1, so re-recording replaces old files. A path that fits a `path_templates` entry (below) is named after the template, e.g. `PUT__books_{id}_1.json`, so recordings for different ids share one name and count. A body is stored as its JSON value when it is JSON, as a string otherwise, `null` when empty, and as base64 in `bodyBase64` when it is not UTF-8. Fixtures are plain files so an agent or a person can edit them. Interception, issue capture and the seed are compiled only into `DEBUG` builds, like the listener.
