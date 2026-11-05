# A decision-model harness for TCA 2

Research date: October 23, 2026. Scope: computer-use agent harnesses, current TCA 2 runtime, and a proposed semantic action harness for this project. This is a design investigation, not an implemented harness or a performance benchmark.

TCA source inspected: private `pointfreeco/TCA26`, revision `315b91ea597feb28015161f0e147bd78959cf682`. Links require repository access. Our app currently resolves this revision from `main`.

## Finding

The useful abstraction is a persistent application execution session with observations, available operations, dispatch, and outcome verification. A decision model supplies a selection inside that loop. A CLI or MCP server exposes the loop; neither replaces the application runtime.

TCA can provide the application runtime and a typed seam for operations. It does not automatically provide a remotely callable action catalog, valid argument enumeration, task completion semantics, or UI visibility information. Those are responsibilities of the proposed harness and participating feature adapters.

## What existing harnesses teach us

Computer-use integrations separate the model from the executor. The application owns the computer environment, executes the suggested operation, and returns a fresh observation. The model does not directly operate the machine merely by producing a tool call. See [Anthropic computer use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool) and [OpenAI computer use](https://developers.openai.com/api/docs/guides/tools-computer-use-integration).

The same separation applies to a semantic TCA harness: Jev chooses; the Swift host validates and executes; the host returns actual resulting state. Never return the model's prediction as an execution result.

Playwright MCP provides a close precedent for structured interaction: accessibility snapshots supply references for targeting actions; screenshots remain available. Its implementation also distinguishes a persistent browser session from the protocol used to access it. See [Playwright MCP](https://github.com/microsoft/playwright-mcp).

MCP standardizes tool discovery, JSON-schema arguments, invocation, structured results, and tool-list change notifications. It is an optional interoperability layer, not a requirement for operating a feature. See [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

OSWorld provides environment setup/reset and task-specific execution-based evaluation, separate from the agent's interaction. The relevant lesson is independent outcome checking against actual environment state. See [OSWorld repository](https://github.com/xlang-ai/OSWorld) and [paper](https://arxiv.org/abs/2404.07972). A semantic harness should have its own evaluation track: state access and direct dispatch give it different capabilities from screenshot-only computer use.

OpenAI also calls out cancellation and time/step limits; OSWorld separates environment setup from outcome evaluation. These belong in the harness independently of the decision model.

## What current TCA 2 contributes

### A real execution runtime without requiring a view

`Store` is main-actor isolated and intended for UI integration. `StoreActor` owns a separate actor isolation domain and is intended for background feature logic. Both create a root core and mount the feature during initialization. They expose state and action dispatch. This is evidence that feature execution is not dependent on mounting a SwiftUI view.

Sources: [store fundamentals](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Documentation.docc/Articles/StoreFundamentals.md), [Store](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Store.swift), [StoreActor](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/StoreActor.swift).

Design implication: a persistent macOS command-line host can potentially run compatible feature logic without an iOS simulator. This is not proof that every iOS feature can run on macOS: UIKit, device services, entitlements, app lifecycle, persistence locations, authentication, and other dependencies still constrain the host. A main-actor feature can use `Store` in a headless process; headless does not require `StoreActor`.

### Actor isolation for coherent execution

The root store establishes the isolation used throughout the feature tree. Scoped and spawned children share that isolation. Synchronous work is serialized; asynchronous suspension permits other work to proceed.

Source: [feature isolation](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Documentation.docc/Articles/FeatureFundamentals/FeatureFundamentals-Isolation.md).

Design implication: marshal commands onto the store's actor. Validate the observation revision and current candidate availability, then dispatch without suspending between validation and dispatch. Jev runs outside that critical section. Isolation alone does not prevent a decision from becoming stale while awaiting a model response.

### Lifetimes for available operations

Features mount and dismount with the feature tree, and identity changes can restart their lifetime. `onMount` is tied to feature lifetime rather than view visibility. Related tasks are tied to that lifetime.

Sources: [feature lifecycle](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Documentation.docc/Articles/FeatureFundamentals/FeatureFundamentals-Lifecycle.md), [OnMount implementation](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/FeatureModifiers/OnMount.swift).

Design implication: register dispatch handlers for a feature instance, invalidate them when that instance goes away, and include a lifetime generation in candidate identity. Do not infer “visible to the user” from “mounted.” Expose an explicit availability policy for application-level operation versus current-screen interaction.

### Composition without one central action pipeline

Spawned children have their own runtime and process actions independently of the parent's action domain. Parents cannot intercept child actions, although state, events, preferences, dismissal, and triggers allow communication.

Source: [Spawn](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Features/Spawn.swift).

Design implication: a root action interceptor cannot discover or dispatch everything. Register each participating feature instance; route through its scoped or spawned store, preserving normal TCA execution.

Preferences allow descendants to contribute values that ancestors combine. This is a promising public mechanism for aggregating candidate descriptions, but it is not an existing agent catalog or arbitrary child-action dispatcher.

Sources: [preferences guide](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Documentation.docc/Articles/FeatureCommunication/FeatureCommunication-Preferences.md), [preference implementation](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Features/Preference.swift).

Proposed approach: keep Codable candidate metadata separate from actor-isolated typed dispatch handlers. Prototype explicit registration first, then investigate preference aggregation for composition. Avoid relying on private core traversal or underscored debugging internals.

### State changes are broader than actions

The SwiftUI store supports bindings, and `FeatureStore.modify` allows tasks to mutate state directly. Async work can update state without sending another action. Store state is observable.

Sources: [Store SwiftUI integration](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Store+SwiftUI.swift), [task management](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Documentation.docc/Articles/FeatureFundamentals/FeatureFundamentals-StoreTaskManagement.md), [FeatureStore](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/FeatureDynamicProperties/FeatureStore.swift).

Design implication: observations and revisions must follow relevant state changes, not just dispatched actions. Some user operations are bindings rather than enum cases; adapters may need typed field-edit operations using the supported mutation path. An action-only catalog cannot promise full feature coverage.

### Async task facilities, without automatic business completion

`send` returns an optional task associated with resulting work. `StoreTaskID` exposes running/error state and can await or cancel identified work. Mount hooks can start long-lived tasks; async work can modify state after the initiating action returns.

Sources: [Store.send](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Store.swift), [StoreTaskID](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/StoreTaskID.swift), [task management](https://github.com/pointfreeco/TCA26/blob/315b91ea597feb28015161f0e147bd78959cf682/Sources/ComposableArchitecture/Documentation.docc/Articles/FeatureFundamentals/FeatureFundamentals-StoreTaskManagement.md).

Design implication: distinguish accepted, running, succeeded, failed, and cancelled operations. Wait for a feature-specific postcondition or a known finite task, with a deadline. Global “wait until no effects remain” can hang on timers or subscriptions and is not a reliable business-success signal.

## Proposed harness

This section is a design recommendation, not an upstream TCA interface.

1. **Persistent host:** owns the actual root store, dependencies, feature registrations, and execution sessions. An iOS app adapter operates its existing store; a headless adapter owns a separate runtime configured for the same shared feature logic.
2. **Observation interface:** returns session ID, feature instance/lifetime, revision, compact relevant state, current candidate descriptors, and operation status. Encode explicit observations rather than dumping arbitrary Swift state.
3. **Dispatch interface:** accepts request ID, candidate ID, expected revision, and optional validated typed arguments. Resolves the candidate in the current host, validates and dispatches on the store actor, and returns a receipt. Store receipts for retry deduplication within the session; crash-safe exactly-once external effects require persistence and dependency-level idempotency.
4. **Watch/wait interface:** returns new observations or operation progress with timeout/cancellation. The first prototype can use bounded polling; subscriptions can follow.
5. **Decision driver:** sends observations and candidates to Jev through the existing Ramp Router configuration; validates returned IDs and abstains/escalates when appropriate. A generative planner or argument extractor participates only when required.
6. **CLI:** thin client for `observe`, `dispatch`, `wait`, and `run --goal`. Start with a long-lived JSON-lines stdio host. Separate CLI invocations need a daemon/local connection or an explicit session host; recreating the store per command would reset the app.
7. **Optional MCP adapter:** exposes the same interface to existing agents. Start with a stable small tool set and put changing candidate catalogs in observations; a tool per candidate could cause unnecessary tool-list churn.

The iOS host still requires a running app process, usually in the simulator during development. Skipping taps does not remove the simulator. The headless host avoids it only for code and dependencies compatible with that host. A headless store is a different instance from the store in the running iOS app; it does not remotely control that app unless connected to its host.

## Offering arbitrary features

Aim for generic harness machinery with explicit per-feature adapters. An adapter supplies the observation projection, candidate descriptions, current availability, typed dispatch, and completion conditions. Enum metadata cannot establish target identity, business preconditions, UI reachability, or business success. Macros may later generate serialization/schema boilerplate from opt-in declarations; automatic semantic inference is not assumed.

For finite targets, bind the operation and target into one candidate (for example `complete:groceries`). Do not independently choose action type and entity if their valid values depend on one another. For large candidate sets, filter deterministically and/or select a feature first and then offer its candidates. Free-form text needs generation or extraction rather than a finite-choice decision alone.

## Jev's role

Jev evaluates typed Choice/Score/Noul questions over supplied state. Multiple questions in one request are independent. Parallel checks are useful, but they do not remove sequential dependencies between app transitions. A “goal satisfied?” prediction on the old state cannot verify the state produced by the selected action.

Source: [TypeSafe primitives](https://docs.typesafe.ai/primitives).

The existing Router key was verified earlier in this thread: its catalog included `jev-1.14.0` and `jev-1.13.0`; one synthetic Jev 1.14 request returned the matching groceries choice in 230 ms. This is a single smoke test, not a latency distribution or an accuracy measurement. Its reported confidence was 0.66, with groceries probability 0.77; those are different fields, neither sufficient to establish calibrated correctness for app control.

Router documents Jev's typed route at `/v1/systemone`: [Router Jev documentation](https://router.com/models/jev-1.13.0). Keep provider access in the local decision driver; do not embed the Router secret in the app bundle or serialized candidate catalogs.

## Verification and evaluation

Use TCA's test runtimes for deterministic feature assertions, and live stores for actual operation. Replay needs controlled dependencies, initial state, clock behavior, and external responses; recording action names alone cannot reproduce binding writes or external side effects.

Measure complete task success, candidate validity, stale-selection rejection, step count, model requests, end-to-end p50/p95 latency, timeout/recovery behavior, and model cost. Verify outcomes independently of the selecting model. Compare identical goals under screenshot interaction and semantic dispatch, explicitly reporting the different access each approach receives. Keep UI tests for rendering, wiring, accessibility, keyboard, navigation presentation, and platform integration.

## First implementation to answer the design question

Extract the task domain into a shared Swift package. Add a persistent macOS host for that domain with `observe` and `dispatch`, revision checks, operation receipts, and explicit task candidates. Prove the loop with scripted choices before adding Jev. Then connect Router and add one asynchronous operation plus a spawned child to exercise completion and routing. Only after those pass should we generalize adapters or introduce macro syntax.

Open questions to test: actor-safe handler registration and lifetime cleanup; propagation of catalogs through spawned features; observation of relevant binding/async writes; postconditions for finite work; host dependency parity; candidate count versus model accuracy; cancellation and idempotent retries.

## Prototype implementation note (October 24)

Current upstream includes `Package@swift-6.3.swift`, so the Swift 6.4 declaration in its default manifest does not require upgrading the installed Swift 6.3.1 toolchain. The prototype uses the compatibility manifest. See `prototypes/tca-harness/README.md` for implementation scope and commands.

## Embedded prototype follow-up

The reusable `TCAHarness` local Swift package now owns the model-independent
session and loopback transport. The separate `DecisionHarness` adapter attaches
to the existing root store inside the iOS app. CLI `--app` uses that in-process
store; default mode still creates an independent headless store. Both modes
passed the scripted scenario, and a live five-decision Jev run updated the visible
iOS UI without UI taps. See `recordings/jev-ios-trace.jsonl`.
