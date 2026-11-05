# Contributing

Thanks for helping out. Issues and pull requests are welcome.

## Layout

- `TCAHarness/`: model-independent session, JSON protocol and loopback transport. No TCA dependency.
- `TCAHarnessTCA1/`: descriptors, runtime and macros for TCA 1.x. Built by the root `Package.swift`.
- `TCAHarnessTCA2/`: the same for the TCA 2 beta. Separate package, needs access to the private beta.
- `cli/`: the `tca` command-line client (Python, standard library only).
- `examples/`, `prototypes/`, `docs/research/`: integration examples, earlier experiments and design notes.

## Running the checks

```sh
swift test                           # TCAHarness + TCAHarnessTCA1, macro and runtime tests
(cd TCAHarness && swift build)       # transport package on its own
python3 -m unittest discover -s cli/tests
```

The devtools and trace viewer checks under `cli/tests/*.js` run when `node` and `jsdom` are available and are skipped otherwise. `TCAHarnessTCA2` builds only with TCA 2 beta access: `cd TCAHarnessTCA2 && swift test`.

CI runs the Swift and Python checks on every pull request.

## Guidelines

- Keep the agent surface small. New protocol fields need a reason an agent or a test can't do without.
- The harness dispatches real actions through the app's store. Don't add paths that mutate state directly, except binding setters that write the way the UI does.
- Keep the CLI dependency-free at runtime.
- Add tests with behaviour changes: macro expansion snapshots for macros, runtime tests against a real store for descriptors, unit tests for the CLI.
- Don't commit model credentials, local paths or third-party app sources. The isowords example fetches its upstream checkout at setup time.
