# Contributing

Thanks for helping out. Issues and pull requests are welcome.

## Layout

- `TCAHarnessCore/`: model-independent session, JSON protocol and loopback transport. No TCA dependency.
- `TCAHarness/`: descriptors, runtime and macros for TCA apps, and `@Observable` model support. Built by the root `Package.swift`.
- `cli/`: the `tca` command-line client (Python, standard library only).
- `skills/`: agent skills for integrating, driving, testing and recording an app.
- `docs/`: the testing guide and notes on adopting the harness in a large app.
- `examples/`: Shelf, a small app with planted bugs for every testing pattern.

## Running the checks

```sh
swift test                                       # TCAHarness and TCAHarnessCore: macro and runtime tests
swift test -c release -Xswiftc -enable-testing   # the same with the listener compiled out
(cd TCAHarnessCore && swift build)               # the core package on its own
python3 -m unittest discover -s cli/tests
(cd examples/shelf && ./run_ladder.sh --skip-ui) # every testing pattern on the headless host
```

The devtools and trace viewer checks under `cli/tests/*.js` run when `node` and `jsdom` are available and are skipped otherwise.

There is no hosted CI; run these before opening a pull request.

## Guidelines

- Keep the agent surface small. New protocol fields need a reason an agent or a test can't do without.
- The harness dispatches real actions through the app's store. Don't add paths that mutate state directly, except binding setters that write the way the UI does.
- Keep the CLI dependency-free at runtime.
- Add tests with behaviour changes: macro expansion snapshots for macros, runtime tests against a real store for descriptors, unit tests for the CLI.
- Don't commit model credentials, local paths or third-party app sources.
