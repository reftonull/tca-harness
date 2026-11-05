# Changelog

## Unreleased

First public release candidate.

- `TCAHarness`: session protocol (`observe`, `dispatch`, `wait`, `verify`, `cancel`), receipts, revisions and loopback transport.
- `TCAHarnessTCA1`: `@HarnessFeature`, `@HarnessSchema` and explicit `FeatureDescriptor`s for TCA 1.x, plus `harnessTimeline()` for the live devtools panel.
- `TCAHarnessTCA2`: the same for the TCA 2 beta (`@Feature`), with bindings, spawned children and stack paths.
- `tca` CLI: `doctor`, `ls`/`do`, `inspect`, `observe`, `dispatch`, `wait`, `cancel`, `devtools`, `trace`, and a bounded model loop (`run`) that works with Router or any OpenAI Responses-compatible endpoint (`tca setup`).
- The listener is compiled out of Release builds.
