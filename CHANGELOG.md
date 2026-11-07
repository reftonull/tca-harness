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
