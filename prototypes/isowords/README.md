> Historical feature host. For embedding into the actual app, use [examples/isowords](../../examples/isowords/README.md).

# isowords live-store harness

This experiment embeds the harness into a simulator app hosting Point-Free's actual `Home` and `Settings` features. It uses TCA 1.13, independently of the TCA 2 demo. It does not yet host the complete shipping game.

Run `python3 prototypes/isowords/setup.py` from the repository root. It prepares an ignored, isolated checkout at upstream commit `c727d3a7c49cf0c98f2fa4f24c562f81e30165f7` and generates an XcodeGen project. An existing local checkout may be supplied with `--source`; it is only read. The original checkout is never patched. Shared client dependency constraints in `examples/isowords/client-pins.json` accommodate the current Swift compiler. Setup also reorders four Game Center client stored properties ahead of endpoint properties for current DependencyClient definite initialization; reducer and view sources are unchanged.

Build and launch with FlowDeck using `prototypes/isowords/flowdeck.json`, your saved simulator, and a derived-data path. The app exposes the same JSON-lines harness protocol on loopback port 8766:

```
./scripts/tca observe --app --port 8766
./scripts/tca run --app --port 8766 --goal 'Open settings' --verify settingsOpen
```

The adapter in `TCAHarnessTCA1` recursively discovers case paths and constructs nested root actions. No parent-action switch is handwritten for Home → presentation → Settings. Optional scopes are offered only while mounted. A lifetime generation helps invalidate operations after a child is dismissed and recreated. A bounded reflection snapshot removes the requirement that application state conform to Codable.

One explicitly writable `Settings.State.userSettings` group generates boolean/enum choices and schema-bearing string/numeric operations. Changes dispatch real TCA binding actions through the discovered parent route. The application chooses the writable group, numeric bounds, redaction fields, and action policy; reflection alone does not establish which actions should be exposed.

## Boundaries

- Structural state/action names must align; `registerState` supplies computed or unusual scopes.
- Collection, identified, stack, tuple and arbitrary associated-value action routing remain future work.
- Mounted reducer state does not establish screen visibility. Some upstream settings navigation is local SwiftUI state.
- Snapshot depth, field count, collection size and text length are bounded. Classes are opaque. Redaction by field name requires application review.
- Dispatch completion acknowledges synchronous dispatch; use explicit state predicates for business completion.
- External services use no-op/in-memory dependencies. This does not exercise production networking, purchases or authentication.
- Original proprietary fonts are absent; a placeholder enables resource compilation and system fonts provide fallback.

Upstream isowords has its own [license](https://github.com/pointfreeco/isowords/blob/main/LICENSE). The setup script fetches its source separately; this repository does not relicense or vendor that application.

## Verified run

The recorded run (video not included) went Home → Settings through Jev, followed by changes on Accessibility and Sounds. The subpage navigation taps are FlowDeck UI automation because those links are view-local; all setting changes go through discovered TCA actions. Jev 1.14 selections took 208 ms (open), 241 ms (haptics), 187 ms (reduced animation), and 291 ms (music operation). Haiku 5.5 generated `{"value":"0.0"}` in 1,861 ms for the numeric operation. These are individual network-inclusive samples, not a benchmark.

After launching a fresh app, `python3 prototypes/isowords/check_live.py` checks optional-scope availability, nested dispatch through presentation/Settings/Stats, boolean and numeric binding writes, rejection of out-of-range numeric input without mutation, and rejection of a stale child candidate after dismissal and reopening. Async view tasks can change revisions; the check re-observes and retries stale revisions. `recordings/live-check.json` contains the transcript.

## Next production milestones

1. Generate explicit state projections and capability metadata at compile time, replacing reflected field-name and underscored identity assumptions. Include diagnostics for unsupported payloads rather than silently treating discovery as complete.
2. Add identified collection and navigation-stack routes with stable entity IDs, presentation lifetimes, and checked root embeddings.
3. Generate recursive argument schemas for associated structs/enums with explicit writable policy and validation. Keep model argument generation independent of dispatch.
4. Host the complete AppReducer and Game feature with deterministic dependencies; validate cube selection, submission and navigation through real UI-backed flows.
5. Stabilize transport/version negotiation, cancellation and effect-completion contracts, privacy projections, and compatibility tests before packaging for public adoption.

## Typed runtime integration (current)

The current host uses `IsowordsRoot.harnessDescriptor`, generated by `@HarnessFeature`, composed with explicit typed descriptors for the upstream Home/Settings/Stats features. The graph no longer infers execution scopes from reflected state field names. Enum/presentation routing is supplied as checked Swift closures; the root and ordinary Settings → Stats routes use typed key paths.

```
./scripts/tca inspect --app --port 8766
./scripts/tca inspect --app --port 8766 --path root/home/settings
./scripts/tca dispatch --app --port 8766 --candidate 'EXACT_ID_FROM_INSPECTION' --arguments '{}'
```

Inspection reveals `root`, `root/home`, and, while Settings is mounted, `root/home/settings` and `root/home/settings/stats`. Operation IDs include runtime instance tokens. `check_live.py` now validates this integration and saves `recordings/runtime-live-check.json`; earlier recordings document the previous discovery adapter.

The original upstream source is still fetched separately and does not need harness annotations. Generated and explicitly supplied feature descriptions share the same runtime contract. The separate `TCAHarnessTCA1/Tests/RuntimeTests` fixture exercises generated input schemas, optional children, collections and navigation stacks; these broader tests do not imply full isowords gameplay support.

Numeric binding arguments in the current runtime use native JSON numbers, e.g. `{"value": 0}`, with minimum/maximum constraints in the schema. The host uses an in-memory UserSettingsClient mock so prior simulator preferences cannot change the initial verification state.

The current runtime also passed live model runs saved as `runtime-jev-haptics.jsonl` and `runtime-jev-music.jsonl`. The latter opened Settings, selected the numeric operation, generated native `{"value":0}` with Haiku 5.5, and verified `musicMuted`. `runtime-inspection.json` and the `runtime-*.jpg` screenshots show the final capability graph and visible state. Subpage navigation was still performed by FlowDeck because upstream stores it locally in SwiftUI.

## Complex workflow recording

`recordings/complex-release-workflow.jsonl` records a separate release-planning sample presented from the isowords host. This is a harness demonstration feature, not upstream isowords gameplay. The entire recorded interaction is driven through the live runtime with no UI automation taps:

1. Jev opens the workflow sheet.
2. Jev selects creation; Haiku 5.5 generates nested input containing a title, summary, and three task records with owners, priorities and original notes.
3. The runtime validates and decodes that input into a real reducer action.
4. Jev targets each generated identified child route and marks the task record complete.
5. Publication only becomes available after all three records are complete. It dispatches a cancellable two-second local simulated save effect, and the CLI waits for its completion predicate.
6. State verification checks the exact title, count, owners, priorities, generated notes, completed records and published phase.

The run took 16.241 seconds including pacing, with six dispatches. Jev classification calls took 163–239 ms; argument generation took 3.821 seconds. These are single-run network-inclusive samples. Task completion changes checklist state; it does not execute the implementation work described in those tasks. No remote publishing is performed.

Replay from a fresh app launch:

```
python3 prototypes/isowords/run_complex.py
```

The runner goal and assertions are versioned alongside the feature. `recordings/complex-release-workflow.jsonl` preserves decisions, generated arguments, receipts, the asynchronous wait, and final verification.
