---
name: record-app-behavior
description: Record a TCA app's screen side by side with the live devtools timeline while a person, script, or agent drives it. Use to capture a bug reproduction, prove a fix, compare before and after, or show a feature working.
---

The result is one video: the devtools panel on one side, the app on the other, in sync, plus the exported timeline JSON as exact evidence of what the store did. The steps below don't depend on specific tools. The [examples](examples) show what worked on macOS with an iOS simulator; check what the current machine has before choosing.

## 1. Decide what the recording must show

Write down the behavior and the moment that proves it, e.g. "tapping Save twice sends two requests" or "the score changes to 24 after submit". Plan to pause on that action afterwards so the panel's Diff, Effects or Mounts tab shows it.

## 2. Prepare a clean run

- The app applies `.harnessTimeline()` to its root reducer and retains `store.harness(...)`. `./scripts/tca doctor --port PORT` should report `timeline: recording (...)`.
- Relaunch the app with `TCA_HARNESS=1` so the timeline starts empty, then start `./scripts/tca devtools --port PORT`.
- Keep the default projected detail unless you need payload values. The video and export contain whatever state the panel shows.

## 3. Choose a capture method for each side

| Side | Requirement | Examples |
| --- | --- | --- |
| App | Real frames of the device or window | `flowdeck simulator record --output-file app.mp4 --stop-file STOP` (used here), `xcrun simctl io <device> recordVideo`, QuickTime for a device, `adb screenrecord` |
| Panel | A browser view that is actually painting | A visible browser window with a screen recorder, Playwright/Puppeteer video recording, or [panel-recorder.swift](examples/panel-recorder.swift) (offscreen WebKit snapshots; used here) |

The simplest option: put both windows on screen and make one screen recording. That needs no syncing or compositing.

Before the real run, record about 3 seconds and check duration and frame rate (`ffprobe`, or [inspect-video.swift](examples/inspect-video.swift)). A hidden or background browser tab can produce a long file with almost no frames. A T3 preview tab that wasn't on screen gave 3 frames in 80 seconds.

## 4. Record

1. Start the app recording, then the panel recording. Note each one's wall-clock start time (the panel recorder prints `START <epoch>`).
2. Drive the behavior: by hand, a script, or an agent (e.g. `python3 examples/isowords/play_word.py`).
3. Optionally walk through the panel afterwards: click the action that proves the behavior, open the relevant tab, and caption it. To script this, run JavaScript in the page ([example tour](examples/isowords-tour.js)). Select rows by action name, since rows shift as new actions arrive.
4. Stop the panel recording, then the app recording right away.
5. Click **Export JSON** in the panel (or save `GET /api/timeline` pages) to keep the exact action log next to the video.

## 5. Align and combine

- Work out how far into the app video the panel's first frame is. Start times give an estimate, but launch delay adds error. Cross-check from the ends: offset ≈ app duration − panel duration − delay between the two stops. They agreed to within 0.1s here.
- Combine side by side, e.g. `ffmpeg -ss OFFSET -i app.mp4 -i panel.mp4 -filter_complex "[0]scale=-2:1080[a];[1]scale=-2:1080[p];[p][a]hstack" -t SECONDS out.mp4`, or [compose.swift](examples/compose.swift) without ffmpeg.
- Extract frames at two or three visible events (a screen change and the matching row appearing) and look at them. Adjust the offset if they disagree.

## 6. Check before sharing

- Watch or sample the final video. Confirm the proving moment is visible and readable.
- Look for secrets or personal data in the app screen, the panel state and the export.
- For a PR, attach with `gh pr create/edit --body-file BODY --attach video.mp4`. If gh appends the video at the end of the body instead of replacing a bare `./video.mp4` line, move the uploaded URL back into place.
- Report what the recording proves and how it was captured, including any manual steps or estimated offsets.
