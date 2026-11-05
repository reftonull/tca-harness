# Prototype recordings — October 24, 2026

Screen recordings of these earlier runs aren't included in this repository; the traces, screenshots and state files are.

- `headless-replay.html`: self-contained interactive terminal replay; open in a browser. Defaults to 0.25× playback while displaying original elapsed timestamps.
- `headless.cast`: asciicast v2 terminal recording, playable with `asciinema play recordings/headless.cast` when asciinema is installed.
- `headless.txt`: readable transcript.
- `headless-trace.jsonl`: actual CLI events and state observations.
- `ios-final.png` and `ios-final-state.json`: final screenshot and accessibility evidence.

The headless run used live Jev 1.14 via Ramp Router, took five decisions and 1,370 ms, and independently verified all tasks complete and the archive saved. The UI run was driven through FlowDeck taps, not Jev. It used a separate store running the same shared TCA domain. Archive saves are asynchronous in-memory simulations in both modes. UI pacing includes automation/tool overhead and is not a latency benchmark.

## Jev driving the real iOS store through the embedded package

The run used the new `--app` path: Jev → CLI → loopback
transport → embedded TCAHarness session → existing root store → SwiftUI. No
FlowDeck taps were used during this run. `jev-ios-trace.jsonl` contains the actual
decisions and receipts; `jev-ios-final.png` and `jev-ios-final-state.json` confirm
the visible Saved state. `jev-ios-initial.json` and `jev-ios-reconnected.json`
show the same session ID across separate CLI processes.

Five decisions completed and archived all tasks in 5,358 ms, including explicit
0.8-second pacing after each decision for recording readability. This is not an
unpaced performance measurement. The archive save remains an in-memory simulation.

## Hybrid typed-argument workflow

This is the successful `hybrid-demo --app --step-delay 0.6`
run. `hybrid-ios-trace.jsonl` is its actual protocol trace; `hybrid-summary.json`
summarizes the model stages. `hybrid-ios-final.png` and the accompanying state
JSON confirm the edited task was completed and its archive saved.

Jev selected create/edit; Claude Haiku 5.5 generated original notes and the typed
fields. Jev then completed the task and opened/saved the spawned archive without
more generation. There were five Jev calls and two generative calls. Total elapsed
time was 8,855 ms including five explicit 600 ms pauses, or about 5,855 ms excluding
that pacing. Generative calls took 1,689 and 2,787 ms. These are single-run
measurements, not a benchmark.

`hybrid-headless-trace.jsonl` captures the first successful headless creation.
`hybrid-validation.jsonl` captures model-free argument-validation scenarios.
