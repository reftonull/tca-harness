---
name: test-tca-app
description: Test a TCA app's behaviour through its harness with journeys (`tca journey run`, `tca record`), random exploration (`tca explore`), fault injection (`tca chaos`), and determinism and rung comparisons (`tca determinism`, `tca diff`). Use when building or fixing a feature in an app with a harness.toml, before opening a PR, or when a journey breaks.
---

Tests here describe what a user does and sees: a goal, steps by label, and checks over the published state. They break when behaviour changes, not when code is refactored. The full design is in [docs/testing.md](../../docs/testing.md); flags are in the [CLI reference](../../cli/README.md#behaviour-tests).

## Setup

- The project needs a `harness.toml` with at least a `headless` target. Without one, `tca journey run --port N` uses an app you already launched, but runs then share its state.
- Journeys live next to the code (e.g. `journeys/*.toml`) with cassettes in a fixtures directory. A journey without `network`/`fixtures` runs with the network blocked.
- Every command exits 0 (nothing found), 1 (found something) or 2 (bad input). Read the summary; add `--report run.jsonl` and `tca trace --input run.jsonl` to see each step's state.

## Which command when

| Situation | Command | Rung |
| --- | --- | --- |
| Building a feature: define done first | Write the journey's `goal` and `[checks]`, solve it with `tca do` while `tca record` runs, then `tca journey run` after every change | headless |
| A journey fails at a step that no longer resolves | Re-solve it (below); don't hand-edit labels | headless |
| Before a PR | `tca journey run journeys/*.toml`, then `tca explore --runs 50` and `tca chaos` on the journeys you touched | headless |
| A bug only shows up with views (onAppear, lifecycle) | `tca diff FILE --targets headless,ui` | headless vs UI |
| Flaky journey or state that differs between runs | `tca determinism FILE` | headless |
| Backend contract may have changed | `tca journey run FILE --network record --target live` and review the cassette diff | live |

## Write a journey by solving it

1. `tca record start journeys/add-book.toml --goal "Add a book called Dune and see it on the shelf"`
2. Drive the app with `tca ls`/`tca do` (the drive-tca-app loop), from the same directory. Only successful steps are recorded.
3. `tca record stop --check "Dune is on the shelf=any(b.title == 'Dune' for b in shelf.books)"`. Check the outcome the user cares about, not intermediate flags.
4. Add `fixtures`/`network` if the flow makes requests, then `tca journey run` it on a fresh launch. It must pass before you rely on it.

Checks are expressions over the root state: attribute access, indexing, comparisons, `and`/`or`/`not`, arithmetic, generator expressions and `len`, `any`, `all`, `sum`, `min`, `max`, `sorted`, `set`. A missing key is `None`.

## When a journey fails

- **Step doesn't resolve**: the output shows the current view, the goal and the remaining steps. Run `tca record start FILE` (it keeps the goal, checks and fixtures), reach the goal again with `tca do`, then `tca record stop`. If the goal itself is no longer reachable, that is a regression: report it, don't rewrite the goal.
- **Check or expect failed**: the app reached a different outcome. Look at the state (`--report`, `tca ls`) before deciding whether the code or the expectation is wrong; ask if unsure.
- **Oracle findings** (crash, issue, invariant, network, stuck, rejected, dead end) are bugs or missing fixtures. An unmatched request in replay means a fixture is missing or the app makes a request nobody expected; find out which before adding a cassette.

## Explore and chaos findings

- Each finding is a minimal journey in `.tca/findings/<kind>-<n>.toml`. Reproduce it with `tca journey run` on the same target, fix the code, and run it again until it fails at the now-unreachable step or passes.
- Keep a finding as a regression journey only if its steps read like something a user would do; otherwise fix and delete it.
- `chaos` reports **stranded** when, after a failed request, neither the next step nor a retry is offered within 5 s: a stuck spinner or a swallowed error. It needs protocol v3.
- Against a protocol v2 app the issue, invariant and network oracles are skipped; the summary says so. Say that in your report rather than claiming those checks passed.

## Reporting

State what ran and on which rung ("12 journeys pass headless; explore 50 runs found nothing; chaos on add-book: 2 requests x 5 faults ok"), list findings with their journey files, and include any notes the CLI printed.
