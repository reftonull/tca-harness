---
name: drive-tca-app
description: Operate a running TCA app through its embedded harness with `tca ls` and `tca do`: explore screens, reach a state, reproduce a bug, or verify a change without tapping the UI. Use whenever a TCA app with the harness is running (launched with TCA_HARNESS=1) and you need to see or change what it is doing.
---

The app publishes what is on screen as state plus the actions available there. You act by sending those actions; the app's own reducers run them and the UI updates from the same state. Nothing you do here taps the screen.

## Connect

- Find the port: the app's launch environment sets `TCA_HARNESS_PORT` (default 8765). Pass `--port N` to every command.
- Run `tca doctor --port N` once. If it can't connect, the app isn't running with `TCA_HARNESS=1`, or it is a Release build (the listener only exists in Debug builds). Fix the launch; don't work around it.
- From a checkout use `./scripts/tca`; if installed, `tca`.

## The loop

1. `tca ls --port N` shows the focused feature (the deepest screen, as a user would see it), its state as JSON, its actions, and the actions its parents lend it ("From root/home: dismissSheet"). Read the state before deciding: it is the truth, not your expectation.
2. `tca do ACTION --port N` runs one action and prints the new view. Give arguments as JSON when the action shows a schema: `tca do setMusicVolume '{"value": 0.25}'`. ACTION can be the name, the label (case-insensitive) or an exact ID from `ls`.
3. Check the printed view. Repeat.

One action per step. Don't chain several `do` calls without looking at the result in between; effects can change state after the receipt.

## When it doesn't go as planned

- **No match / ambiguous**: `do` exits 2 and lists the choices without dispatching anything. Pick an exact ID from the list.
- **The action you want isn't listed**: it isn't available in this state. Look at the state for why (a sheet is open, a field is empty, a game isn't started) and navigate there first. `tca ls --all` shows every mounted operation, including ones on other screens.
- **`stale_revision`**: the app changed between your `ls` and `do`. Run `ls` again.
- **`invalid_arguments`**: the arguments don't match the schema. The error says which field.
- **Receipt `failed` or `cancelled`**: the action ran but its effect failed or the screen was dismissed. Read the state to see what actually happened.

## Prove results with state

When the task has an outcome ("the task is archived", "the score is above 20"), finish by showing it in `tca ls` output or `tca observe` state, not by describing what you did. If the user needs to see it, take a screenshot or recording of the app too (see the record-app-behavior skill), and use `tca devtools` to show the exact actions and diffs.

## Keep the path as a test

If the path you just found is worth keeping (a flow you built or fixed, a bug reproduction), record it as a journey: `tca record start journeys/NAME.toml --goal "..."` before the first `do`, run the `do` steps from the same directory, then `tca record stop --check "NAME=EXPR"` with the outcome as a check over the state. Only successful `do` calls are recorded, so dead ends you backed out of don't end up in the journey. The test-tca-app skill covers running and repairing journeys.

## Boundaries

- Only use actions the harness offers. Don't edit app state, databases or files to get somewhere faster.
- Some screens have actions the harness doesn't expose (gestures, text fields without an annotation). Say so instead of guessing; adding an operation is an app change (see integrate-tca-harness).
- The harness drives a real app with real dependencies unless the app swapped them. Ask before actions with outside effects (purchases, sending messages, deleting data).
