# Earlier experiments

Start with the [packages and current integration example](../README.md). These directories preserve the experiments that led to the current design:

| Experiment | Purpose |
| --- | --- |
| [isowords](isowords/README.md) | Isolated Home/Settings host and a separate release-planning demo |
| [harness-validation](harness-validation/README.md) | Current macro/runtime validation wrapper |

The Home/Settings host and release-planning recording are not the full isowords app. The [actual app integration](../examples/isowords/README.md) lives under `examples/` and is the recommended reference for embedding the package.

## TCA 2 experiment

The [task prototype](tca-harness/README.md), original `DecisionsTCA/` / `DecisionsPackage/`, and top-level `recordings/` contain the earlier headless, text-input, and archive demos. They require private TCA 2 access and remain available for replay. The current TCA 1 packages and isowords integration use public dependencies.
