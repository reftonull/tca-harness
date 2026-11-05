# Security

The harness gives a local process control over a running app. Treat it as a debugging tool.

- The listener binds IPv4 loopback (`127.0.0.1`) only and has no authentication. While it runs, any process on the machine can read the published state and dispatch operations.
- It starts only in Debug builds launched with `TCA_HARNESS=1`. Release builds compile the listener out.
- Published state is whatever the feature descriptors expose. Use `@HarnessIgnore` and redaction for secrets and personal data. The devtools panel hides action payloads by default.
- The optional model loop sends the goal, the published state and the offered operations to the provider you configure. Nothing is sent unless you run `tca run` (or another model-driven command) with credentials.
- Model credentials are read from the environment or `~/.config/tca-harness/model.env` (written with mode 0600 by `tca setup`). They are never written to traces.

Don't ship builds with the harness enabled, and don't expose the port beyond loopback (for example via port forwarding).

## Reporting a vulnerability

Please report security issues privately via [GitHub security advisories](../../security/advisories/new) rather than a public issue.
