# Changelog

## Unreleased

First public release candidate.

- `TCAHarness`: session protocol (`observe`, `dispatch`, `wait`, `verify`, `cancel`), receipts, revisions and loopback transport.
- `TCAHarnessTCA1`: `@HarnessFeature`, `@HarnessSchema` and explicit `FeatureDescriptor`s for TCA 1.x, plus `harnessTimeline()` for the live devtools panel.
- `TCAHarnessTCA2`: the same for the TCA 2 beta (`@Feature`), with bindings, spawned children and stack paths.
- `tca` CLI: `doctor`, `ls`/`do`, `inspect`, `observe`, `dispatch`, `wait`, `cancel`, `devtools`, `trace`, and a bounded model loop (`run`) that works with Router or any OpenAI Responses-compatible endpoint (`tca setup`).
- The listener is compiled out of Release builds.
- `HarnessLiveGuard` (`HarnessNetwork.shared.liveGuard = .readOnly(hosts:)`): `record` and `live` refuse anything but GET/HEAD to the listed hosts; the `network` method can't remove it.
- `FeatureDescriptor.operation(_:label:available:completion:cancel:action:)` with `action: (State) -> Action`, for actions that carry the value on screen.
- Journeys, explore, chaos and the other runners wait for launch effects to settle (the post-run quiet rule) before the first step.
- Example: Critical Maps, a production app, integrated with a read-only guard against its live service.
- Example: Shelf plants `double-save` as the realistic race (Save tappable while its POST is in flight), found by `tca explore --races`, and `stale-search` (a catalog search that doesn't cancel the one in flight), found by `tca chaos --reorder`.
- Fixture tooling for server-driven apps:
  - Every logged request says how it was answered (`match`: `exact`, `ordered`, `template`, `path`, `synthetic`, `fault`, `blocked`, `live`) and which `cassette`; the `network` snapshot counts `pending` requests. Additive, no protocol version change.
  - `match.json` matching rules beside the cassettes: `ignore_query`, per-path `ignore_body`, `path_templates` (one cassette for `/users/{id}`; recordings are named after the template) and `pagination` terminal pages.
  - `tca fixtures coverage` (per-endpoint match kinds, unused cassettes, fallbacks; `--strict`) and `tca fixtures record` (record, sanitize, then coverage).
  - Journey steps declare the requests they make (`requests = ["GET /books"]`, `launch_requests`), checked as a multiset after quiet; `tca record` writes them.
- Races:
  - Replay latency: `HarnessLatency` (fixed, per path, and a jitter that is a pure function of the seed, endpoint and occurrence), from `TCA_HARNESS_LATENCY`, the `network` method, `match.json` `latency`, a journey's `latency`, or `--latency`/`--jitter` on every runner.
  - Journey steps `no_wait = true` (dispatch without waiting for the previous step) and `after_ms` (the gap); raced receipts are settled, and checked for stuck, when the race ends.
  - `tca explore --races`: doesn't wait while something is in flight, biased toward double taps and dismissals; findings record each step's timing and the latency, and shrink with it.
  - `tca chaos --reorder`: holds back the first of several same-endpoint requests in a step or race; fails on oracles, checks, or a final state that differs from the in-order run (`stale`).
  - `TCA_HARNESS_FAULTS` and `[[faults]] at = "launch"` fail requests made before the CLI connects; `tca chaos` now faults launch requests too.
  - Runs wait for in-flight requests (up to `--wait-ms`) before calling the app quiet.
