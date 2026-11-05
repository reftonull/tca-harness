# TCAHarness — embeddable prototype

An in-process execution session and local JSON-lines transport for agent-driven
Swift apps. The app supplies its existing store through typed closures. This
package does not create a second store, own a model, or know any task-specific
actions. It has no dependency on the example app or TCA itself; typed TCA
integration lives in the app's adapter.

Requires Swift 6.3 or later and iOS 17 / macOS 14 or later (it uses Observation).

## Add it to an app

For a TCA 1 app, use the root package's `TCAHarnessTCA1` product and the [Store attachment](../TCAHarnessTCA1/README.md#attach-to-the-existing-store). For a custom model-independent adapter, link the `TCAHarness` product from the root package. The standalone core manifest remains for the separate TCA 2 experiment.
Retain the session and server for as long as the root store is alive:

```swift
import TCAHarness

// Run setup and handlers on MainActor, like a UI Store.
let session = HarnessSession(
  snapshot: { MyObservation(count: store.count) }, // Codable & Equatable
  offers: {
    [HarnessOffer(id: "counter/increment", feature: "counter", label: "Increment counter") {
      store.send(.incrementButtonTapped)
      return .completed
    }]
  },
  verify: { condition -> Bool? in
    condition == "positive" ? store.count > 0 : nil
  }
)
let server = HarnessServer { data in await session.handleJSON(data) }
try server.start(port: 8765)
```

`MyObservation` is an app-defined value, not a package type. Actions and stores
remain native Swift values captured in actor-isolated closures. Only observations,
candidate descriptors, requests, and receipts are encoded.

For asynchronous work, return `HarnessOperation { ... }` whose closure reads
current feature state and returns `running`, `succeeded`, `failed`, or `cancelled`.
Supply a lifetime-aware status closure for a child that may disappear. Rebuild the
candidate list from current state on each observation. The example task adapter
is in `DecisionsPackage/Sources/DecisionHarness/TaskHarness.swift`, built from macro-generated
descriptors ([TCAHarnessTCA2](../TCAHarnessTCA2/README.md)).

## Transport

`HarnessServer` accepts newline-delimited JSON on IPv4 loopback only. The same
`HarnessSession.handleJSON` can be attached to another transport, including stdio.
The protocol supports `observe`, `dispatch`, `wait`, and `verify`; see the
[prototype commands](../prototypes/tca-harness/README.md).

The listener is unauthenticated and intended only for a trusted development
machine. Any local process can connect while it is enabled. It is compiled only
when `DEBUG` is defined (the Debug configuration in SwiftPM and Xcode): in other
builds `HarnessServer` keeps the same API but contains no network code,
`start(port:)` throws, and `HarnessServer.isAvailable` is `false`. The TCA
adapters' `startIfEnabled()` additionally requires `TCA_HARNESS=1` at launch.
It is not a production or physical-device transport. Stop it with `server.stop()`.

Candidate availability is checked again at dispatch. Session IDs prevent commands
from targeting a different launch, observation revisions reject changed state,
and in-memory request receipts deduplicate matching retries. These are prototype
controls, not durable exactly-once execution. The adapter must publish all state
relevant to a candidate's validity; revision comparison only sees that projection.

Terminal operation results are recorded when the session observes/checks the
operation or before another harness command mutates state. If an unrelated UI
mutation destroys a completed child before its result is sampled, a status closure
may report cancellation. Apps that need durable operation history should keep
that history outside the child lifetime.

## Operations with generated arguments

An offer can declare a typed argument object and a wire schema. The host validates
field names, required fields, types, string bounds, and enum values, decodes the
Swift type, and runs the supplied domain validator before invoking `perform`:

```swift
struct MessageArguments: Decodable { let text: String }

let offer = HarnessOffer(
  id: "message/compose", feature: "message", label: "Compose a message",
  arguments: MessageArguments.self,
  schema: HarnessArgumentSchema(properties: [
    "text": HarnessStringField("Message body", minLength: 1, maxLength: 1000)
  ]),
  validate: { value in
    if value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw HarnessArgumentError("Message cannot be blank")
    }
  }
) { value in
  store.send(.composeSubmitted(value.text)) // App-specific action.
  return .completed
}
```

This prototype supports **flat objects of string fields**, including finite enum
fields. It is not a general JSON Schema validator. The app still owns semantic
validation (for example, valid calendar dates and available targets). Invalid
arguments return `invalid_arguments` plus `detail` without dispatching an action.
Reusing a request ID with changed arguments returns `request_id_conflict`.

The model is outside the package. The `tca run` loop asks a model to choose one
offered operation and, when it has an argument schema, to fill that schema. Finite
operations with no schema skip the generative call entirely.

## Typed capability runtime

The `TCAHarnessTCA1` package adds generated/explicit feature descriptors and a runtime over the app's existing store. Protocol v2 accepts nested JSON argument objects and supports `inspect` (optional feature `path`) and `cancel` (operation `requestID`) in addition to existing session operations. Inspection returns mounted features, their instance IDs, and currently available operations. The shared schema validator checks types, fields, choices and supported constraints before application decoding. Explicit cancellation hooks are optional; unsupported cancellation returns an error.
