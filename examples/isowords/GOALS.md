# isowords agent goal runs

Executed October 24, 2026 on the original upstream app in the iPhone 17 Pro simulator. Jev `jev-1.14.0` selects operations through Router; `claude-haiku-5-5` generates typed numeric arguments. The adapter is attached to the original root TCA store.

[Final screenshot](recordings/complex-goals-final.jpg) · [Transcript](recordings/complex-goals.jsonl) · [Machine-readable report](recordings/complex-goals-report.json)

## Final run: 7 of 8 checks passed

| Goal | Result | Elapsed | Jev / Haiku calls |
| --- | --- | --- | --- |
| Dark mode + reduced animation + haptics off + 25% music | passed | 8.02s | 6 / 1 |
| Home → Solo → Unlimited; wait for readiness | passed | 2.10s | 2 / 0 |
| Select a face, clear the mistake, preserve score | passed | 3.06s | 2 / 0 |
| Find and submit three distinct words; replan from observed board | passed | 37.27s | 21 / 0 |
| Game menu → Settings → 12% music → board; preserve progress | passed | 5.24s | 4 / 1 |
| Return Home, resume same score/words/board with a new reducer identity | passed | 6.04s | 3 / 0 |
| Ask to type a player name with no exposed typing capability | failed | 0.17s | 1 / 0 |
| Attempt an action captured from a dismissed Settings reducer | passed | 0.03s | 0 / 0 |

The three accepted words were **AROINT (162)**, **DURAIN (180)**, and **FAINLY (288)**: **630 points**. These come from the system-word-list bootstrap dictionary, which includes unusual words; this is not the commercial dictionary. Face count changed from 27 to 28 during play. The planner read the current board again after each word rather than relying on the initial observation.

The settings goal also attempted volume `1.5`, outside the schema's `0...1` range. The runtime returned `invalid_arguments` and left state unchanged. The stale-scope probe used a previously captured candidate with the current revision; it returned `unavailable_candidate` without mutation.

## Timing

Jev: 39 calls, observed median **184 ms**, maximum **398 ms**. Haiku: two calls, **939 ms** and **2,034 ms**. Successful dispatch RPC: 57 calls, median **17.48 ms**, maximum **46.91 ms**. These are client-observed local/network wall times from this run, not a simulator-driving comparison or a statistically powered benchmark. The simple median statistic uses the upper middle sample for an even sample count.

Goal times include default 0.8-second pacing after each successful dispatch, passive renderer-readiness polling and a three-second presentation settling delay before resume. No coordinate taps or keyboard events drove the app.

## Failures and changes across attempts

- **First pass: 4/8.** The runner classified again before the initial game was ready and opened an unrelated menu. Subsequent face goals correctly refused unexpected actions. Added a bounded passive readiness wait and increased pacing from 0.2 to 0.8 seconds. [Report](recordings/complex-goals-first-pass-report.json), [transcript](recordings/complex-goals-first-pass.jsonl).
- **Second pass: 6/8.** Three words scored 792 points, but an immediate exit/resume restored game data while leaving the board loading. A targeted retry waiting three seconds after exit restored the board and preserved all 792 points. This supports a presentation/lifecycle timing explanation; it does not establish the exact upstream cause. [Report](recordings/complex-goals-second-pass-report.json), [transcript](recordings/complex-goals-second-pass.jsonl), [retry evidence](recordings/complex-goals-resume-probe.jsonl).
- **Final pass: 7/8.** The explicit transition delay allowed resume to verify score, played words, face geometry, readiness and a fresh reducer instance. The delay remains an example-specific workaround, not a production completion mechanism.
- **Unsupported typing failed in all three attempts.** Jev selected an unrelated operation at low confidence instead of choosing `none`. The runner inspected the choice and did not dispatch it. Generic `cli run` does not currently apply this goal-specific guard. Confidence alone is not a proven universal threshold: legitimate multi-part settings decisions also had modest confidence. Capability matching/abstention and an escalation policy need separate evaluation.
- Navigation dispatches that unmount their originating child can receive a `cancelled` receipt despite successfully changing root state. The suite verifies resulting state instead of treating a receipt as business success. Receipt semantics for navigation need further work.

## What this does and does not establish

The goals and their success predicates are authored in `run_goals.py`. Navigation/settings have bounded model loops. Gameplay has a deterministic dictionary/path planner, Jev selects the planned face actions and submission, and gesture release is mechanical. This is a live multi-capability integration exercise, not evidence of general LLM planning or word solving.

Checks inspect reducer state and the final board was visually checked in the simulator. Settings bindings are verified in reducer state; offline no-op audio/settings streams do not establish audible volume, persistent settings, or app-wide appearance changes. Resume is within a running app with in-memory saved-game state. Multiplayer, server-backed challenges, purchases, durable persistence, and arbitrary text entry are outside this adapter's exposed slice.

For production, the clearest next targets are explicit lifecycle/completion signals, more precise navigation receipt semantics, capability-aware rejection/escalation of unsupported goals, and a broader repeated-run evaluation set. The current results are individual development runs, not reliability estimates.
