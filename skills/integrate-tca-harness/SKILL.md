---
name: integrate-tca-harness
description: Embed the TCA agent harness in an existing Composable Architecture app and verify a real application workflow.
---

Attach the harness to the app's actual root store. Preserve its reducers, navigation, and views; avoid substituting a demo host for the requested app.

- Locate the app entry point, root Store, and feature composition. Check the harness adapter against the app's resolved TCA version; don't assume the sample's dependency pins apply.
- Add the root Swift package and link `TCAHarnessTCA1`. Use `@HarnessFeature` / `@HarnessSchema` where convenient, or explicit `FeatureDescriptor`s for existing features. Compose children with typed state projections and action embeddings.
- Expose useful operations and intentional state projections. Add availability, argument validation, and completion predicates where behavior needs them. Dispatch real actions; don't mutate store state from the harness. Binding operations (`.binding(.set(...))`) are fine: they write the same way the UI's bindings do.
- Retain `store.harness(Feature.self)` (or `store.harness(descriptor:)`) alongside the store. Call `startIfEnabled()` and opt in with `TCA_HARNESS=1`; `TCA_HARNESS_PORT` optionally selects a port. Models can remain outside the app.
- Optionally apply `.harnessTimeline()` to the root reducer and use `./scripts/tca devtools --port PORT` to watch every action, effect and state change while testing.
- Run `./scripts/tca doctor --port PORT`, then `./scripts/tca exposure --port PORT` to see every feature the descriptor can mount and the action cases left unexposed with their reasons (settle each `unannotated` and `unsupported payload` case: expose it, or `@HarnessIgnore` it), inspect capabilities, then exercise a real feature and verify its resulting state and UI. Distinguish dispatched actions from completed effects. Report any mocked services, deterministic helpers, or manual navigation used.

For current APIs, read the [package guide](../../TCAHarnessTCA1/README.md). The [Critical Maps embedding](../../examples/criticalmaps/CriticalMapsHarness.swift) demonstrates attaching to an existing app without replacing its root reducer, with explicit descriptors over upstream modules; [Shelf](../../examples/shelf/Sources/ShelfCore/ShelfHarness.swift) shows a smaller app, including vanilla `@Observable` screens. These are examples, not a required app structure.
