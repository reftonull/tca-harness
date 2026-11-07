# tca: the harness CLI

`tca` connects to a TCA app that embeds the harness listener. You can inspect the app, dispatch its typed operations, watch its actions, and optionally run a bounded model loop toward a goal. It needs Python 3.10+ and uses only the standard library.

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

`ls` and `do` always connect to the app.

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
- both providers against a mocked network
- `setup`
- the devtools relay and connection failures

The devtools panel checks drive `devtools.html` against a recorded isowords timeline in jsdom. They run when Node can `require("jsdom")` and are skipped otherwise. To enable them, run `npm install jsdom` in a scratch directory and set `NODE_PATH` to its `node_modules`.

## TCA 2 task experiment

In a checkout, running without `--app` builds and launches the historical headless task host in `prototypes/tca-harness`. That demo requires private TCA 2 access, XcodeGen, and FlowDeck. You don't need it to use the CLI against an existing app.

Task-specific demo commands are documented in [the prototype guide](../prototypes/tca-harness/README.md). The isowords scripts load `cli/tca.py` directly and don't need the task host or TCA 2. They pin Router model IDs, so run them with Router credentials.
