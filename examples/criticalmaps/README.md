# Critical Maps: a production app against a live public service

[Critical Maps](https://github.com/criticalmaps/criticalmaps-ios) (MIT, TCA 1.26.2) shows cyclists' positions on a public map and runs a public chat. This example attaches the harness to its original root store (`CriticalMapsApp.store`), runs every testing pattern on a headless host and on the simulator, and records fixtures from production without ever writing to it.

Upstream is fetched at a pinned revision (`ef2e06d`, October 2026) into `.upstream/` (ignored by Git) and patched in two places. Reducers and views are unchanged.

## Files

| Path | What |
| --- | --- |
| [setup.py](setup.py) | Fetch the pinned revision, apply the two patches, link the harness file into the app, generate the Xcode project |
| [CriticalMapsHarness.swift](CriticalMapsHarness.swift) | Everything the harness sees: run dependencies (network guard, fixed location, isolated storage), descriptors, invariants, fakes |
| [headless/](headless) | Mac Catalyst host running the upstream `AppFeature` with no UI, plus the view-lifecycle actions the views would send |
| [project.yml](project.yml), [flowdeck.json](flowdeck.json) | The upstream iOS app target for the simulator (iPhone 17 Pro) |
| [harness.toml](harness.toml) | Targets `headless`, `headless-returning`, `ui`, `live` |
| [journeys/](journeys) | Six core flows; all pass on both rungs (two need `--pace` on the simulator, see finding 6) |
| [findings/](findings) | Minimal journeys that reproduce each bug below; they fail on upstream |
| [proof/](proof), [recordings/live-guard-proof.txt](recordings/live-guard-proof.txt) | Proof that recording can't write to production |
| [fixtures/criticalmaps](fixtures/criticalmaps), [fixtures/sanitize.py](fixtures/sanitize.py) | Sanitized cassettes; raw recordings stay in the ignored `fixtures/raw` |

## Run it

Needs Xcode 27 / Swift 6.4, XcodeGen and FlowDeck. From this directory:

```sh
python3 setup.py                                       # fetch + patch + xcodegen (--no-project for headless only)
(cd headless && swift build --triple arm64-apple-ios-macabi)
../../scripts/tca journey run journeys/*.toml           # rung 1, replay: 6 passed, ~1 s each
../../scripts/tca explore --runs 30 --fixtures fixtures/criticalmaps --network replay
../../scripts/tca chaos journeys/mastodon-feed.toml

flowdeck build --config flowdeck.json                    # rung 2
../../scripts/tca journey run journeys/launch.toml --target ui
```

To drive it yourself: `headless/.build/out/Products/Debug-maccatalyst/criticalmaps-headless --port 8790` with `TCA_HARNESS_NETWORK=replay TCA_HARNESS_CASSETTES=$PWD/fixtures/criticalmaps TCA_HARNESS_SEED=0`, then `tca ls --port 8790`.

## Safety: nothing reaches production but reads

Harness runs never send a location or a chat message to criticalmaps.net, and never use the device's location.

- **Default block.** In a harness run without `TCA_HARNESS_NETWORK`, every request fails and is reported. Journeys use `replay`.
- **Read-only live guard.** `CriticalMapsHarness.prepare` sets `HarnessNetwork.shared.liveGuard = .readOnly(hosts: ["criticalmaps.net", "criticalmass.in", "mastodon.social"])` (a harness addition, see below). In `record` and `live`, only GET/HEAD to those hosts leave the process. The location `PUT /locations` and chat `POST /messages` fail as if offline and are reported as `network` findings. The guard is set in-process; `tca` can switch the mode over the wire but can't remove it.
- **Both sessions routed.** `NetworkDispatcher` uses TCA's `urlSession` dependency, overridden with `HarnessNetwork.configure(.ephemeral)`. MastodonKit uses `URLSession.shared`, covered by `HarnessNetwork.install()`. No other in-process networking exists at this revision. MapKit tiles and `AsyncImage` are outside the harness; fixtures carry no image URLs, so no images are fetched.
- **Fixed location.** `locationManager` is a fake at Alexanderplatz (52.5219, 13.4132). `CRITICALMAPS_HARNESS_LOCATION=allow|deny|granted|denied` picks the permission story. The simulator's own location was set to the same point.
- **Proof.** [recordings/live-guard-proof.txt](recordings/live-guard-proof.txt): in `record` mode, the GETs went out (`source=live`) and the location PUT was refused (`source=blocked`). After switching to `live` over the wire, the chat POST was refused too. To reproduce: `tca journey run proof/live-guard-chat.toml --target live --network record` (and `-location`). Each fails with a `Refused ...` network finding.
- **Volume.** About 18 real GETs in total across all recording and proof runs. Nothing else was sent.
- **Fixtures are sanitized.** Rider IDs and positions, and Mastodon accounts, text and media, are replaced. Public ride listings are kept. Timestamps are moved onto the harness's fixed date. Chat messages and write acknowledgements are synthetic and marked with `"note"`.

## What's exposed

| Screen (path) | Operations |
| --- | --- |
| What's New (`root/whatsNew`) | Continue, Close |
| Map (`root`) | Open chat and Mastodon, Open settings, Show upcoming rides, Change map tracking, Share the next ride, and time: "Let 30 seconds pass" (posts location), "Let a minute pass" (refetch) |
| Upcoming rides (`root/rides`, rows `root/rides/<n>`) | Show this ride on the map, Swipe down, Close with the VoiceOver escape gesture |
| Social (`root/social`, `/chat`, `/mastodon`, toots `/mastodon/toots/<id>`) | Show chat/Mastodon, Close; Type and Send a message, Dismiss the error; Pull to refresh, Reload, Scroll to the end of the feed; Open toot, Open author |
| Settings (`root/settings`, `/rideEvents`, `/appearance`, `/privacyZones`) | Observation mode, info overlay and highlight on/off; seven links (recorded in `openedURLs`, not opened); event settings (on/off, radius, per-type show/hide); theme and app icon; privacy zones on/off; Back, Close |

Observation is a user's view: sheet, rider count, your position, GPS permission and whether it's updating, next ride and banner, chat badge, what each tab shows (the Mastodon `screen` follows `TootsListView`'s precedence), draft, alerts.

Invariants (root unless noted): the map shows the riders that were fetched; no rider appears twice; the unread badge never exceeds the messages; the open chat shows the messages the app fetched; no message or toot is listed twice (chat, Mastodon); event settings and appearance screens match the saved settings.

**Not exposed:**
- The GPX file importer and privacy-zone creation, which need a system file picker and a map drag.
- "Route to event", which opens Apple Maps.
- App Intents and Live Activities.
- On the UI rung, the map's visible-rider count and centering. `MKMapView` follows the OS location authorization, which the fake location manager never requests, so the map stays on its default region and `riderCountShown` stays 0 while the store has you in Berlin with 12 riders.

## How it's wired, and what was hard

- **Two patches.** The `CriticalMapsKit` manifest gets `.macCatalyst(.v17)`, which the headless build needs (without it SwiftPM defaults Catalyst to 13.0), plus five products for modules the harness file imports. `iOS/App.swift` gets `.harnessTimeline()`, retains the harness, and calls `CriticalMapsHarness.prepare` inside upstream's existing `prepareDependencies`.
- **Internal state.** `AppFeature.State.destination`, `SettingsFeature.State.destination` and `RideEvents.State.rideEvents` are internal, so explicit descriptors can't read them with key paths. They're read with `Mirror`, through the `@Presents` backing storage. Shared settings that are internal on `AppFeature` (`rideEventSettings`, `hasConnectionError`) are read through their public `@Shared` keys, which share storage with the app's.
- **State outside the store.**
  - The observation-mode, info-overlay and highlight toggles in Settings and What's New are view-local `Binding($userSettings)` writes, with no action. They're exposed as `.binding(.set(\.userSettings.x, …))`, which writes the same `@Shared` storage (the setter is deprecated, not unavailable).
  - `chatReadTimeInterval`, `sessionID` and `lastSeenWhatsNewVersion` live in `@Shared(.appStorage)`; settings live in `.fileStorage`. Both are redirected to an emptied UserDefaults suite and `.inMemory` per run, so every run is a fresh install.
  - `visibleRidersCount` is written by `MKMapView` and only exists on the UI rung.
- **View lifecycle.** The headless host sends what the views send: `AppView.onAppear` at launch; `ChatView` and `MastodonFeedView` `.onAppear` when their tab shows; `SettingsView.onAppear` on open and whenever a pushed page is popped.
- **Time.** The poll timer (post location at 30 s, refetch at 60 s) is set to a day. Runs advance it with explicit operations, which send the same `RequestTimer` actions.
- **Determinism.** The fixed date, UTC calendar and `appVersion` give identical runs (`tca determinism journeys/mastodon-feed.toml`: 3 runs equal). The date flows into requests too: the next-ride query asks for January 2026, so the recorded rides are January 2026 and needed no rebasing.

## Findings

Each has a minimal journey in [findings/](findings). They fail on upstream `ef2e06d` (headless unless noted), are app bugs rather than harness or fixture artifacts, and weren't fixed here.

1. **Location isn't tracked after allowing access on first launch.** [location-not-tracked-after-allowing.toml](findings/location-not-tracked-after-allowing.toml). On `didChangeAuthorization(.authorizedAlways)`, `MapFeature` calls only `requestLocation()` (one fix). `startUpdatingLocation()` runs only from `locationRequested` when permission was already granted at launch. A new user who allows access shares the position from that moment until they relaunch the app. Reproduces on the UI rung (`gps.updating == false`).
2. **Observation mode never stops (or restarts) the GPS from Settings.** [observation-mode-keeps-gps-on.toml](findings/observation-mode-keeps-gps-on.toml), run with `--target headless-returning`. `SettingsFeature.view(.observationModeChanged)` guards on `isObserving != state.userSettings.isObservationModeEnabled`. The value comes from that same shared setting's publisher, so the guard always returns early (the timeline shows the action arriving on every toggle). No position is posted in observation mode, because `postLocation` checks the setting, but the GPS keeps running. Turning observation mode off never starts updates, which compounds finding 1.
3. **The open chat doesn't show new messages, and they come back as an unread badge.** [chat-does-not-update-while-open.toml](findings/chat-does-not-update-while-open.toml). Found by hand and by `tca explore`, shrunk 16→5 steps: [explore-chat-invariant.toml](findings/explore-chat-invariant.toml). While the chat is open, the poll's `fetchChatMessagesResponse` writes into `AppFeature.State.socialState`, a copy that is never presented, and counts the new messages as unread. The user reading the chat doesn't see them; after closing it, the badge says 1. On the map the badge never updates, because chat is polled only while the sheet is open.
4. **Mastodon stays on the error screen after a successful reload.** [mastodon-error-sticks-after-reload.toml](findings/mastodon-error-sticks-after-reload.toml). Found by hand and by `tca chaos journeys/mastodon-feed.toml`, 8 stranded results. `TootFeedFeature` sets `error` on failure and never clears it, so after one failed load, Reload fetches 40 toots and the screen still shows the error. A failed "load more" is worse: it replaces all 80 loaded toots with the error screen and sets `hasMore = false`. A failed first load shows the "no toots" empty state, not an error. Reproduces on the UI rung with `--pace 1`.
5. **VoiceOver users can't close the upcoming-rides sheet with the escape gesture.** [rides-voiceover-escape.toml](findings/rides-voiceover-escape.toml). `RideEventBottomSheet` sends `RideEvents.Action.dismiss` from `.accessibilityAction(.escape)`. The reducer returns `.none` for it and `AppFeature` doesn't handle it. On the UI rung this journey passes, because of finding 6: the previous sheet's late `onDismiss` closes this one.
6. **A sheet opened right after another closes is closed by the previous sheet's dismissal (UI rung only).** [sheet-closed-by-previous-dismissal.toml](findings/sheet-closed-by-previous-dismissal.toml), found by running the journeys on the simulator (`tca diff ... --targets headless,ui`: `sheet: "social" vs null`). Every sheet's `onDismiss` sends `.whatsNewDismissed` or `.dismissDestination`, both of which set `destination = nil`. They fire when the dismissal animation ends, so a sheet opened within that window is closed again, and TCA reports an `ifLet` action for absent state. The device timeline shows the order: agent `socialButtonTapped`, then app `whatsNewDismissed`, then `dismissDestination`. A person sees the chat refuse to open right after tapping Continue, or settings refuse to reopen right after closing them. With `--pace 1` every journey passes. [Screenshot](recordings/race-chat-closed.png).

**Lower confidence (seen in state, not shown in the UI):** a failed chat load renders as "No chat activity" with no retry, because `ChatView` shows the empty state when `messages` is empty, and `.error` has no elements. Chaos counted it as fine because typing is still offered. **From reading the code only:** the send button is hidden with `.opacity(0)` but stays tappable, so an empty or duplicate message can be sent.

## Results

| Run | Rung | Result |
| --- | --- | --- |
| `tca journey run journeys/*.toml` | headless | 6 passed (0.6–1.1 s each) |
| same | ui | 4 passed; appearance and chat-send fail on finding 6, both pass with `--pace 1` |
| `tca explore --runs 30` (seeds 0 and 1) | headless | 1 real finding (3, twice); 1 harness artifact, fixed (below) |
| `tca chaos` on all 6 journeys | headless | chat 10/10 ok; Mastodon 8 stranded (finding 4); 4 journeys make no requests after launch |
| `tca determinism journeys/mastodon-feed.toml` | headless | 3 runs equal |
| `tca diff findings/sheet-closed-by-previous-dismissal.toml --targets headless,ui` | both | differs after step 2 (finding 6) |

**Triaged as artifacts:**
- An invariant "no location is posted in observation mode" fired flakily in explore. It compared network log sequence numbers, which are assigned when a request completes, so a PUT started before the toggle could complete after it. It was removed: the harness can't attribute a request to the action that started it.
- Chaos counts Mastodon's first-load failure as stranded because the retry is a different operation (Reload) from the step that failed (Show Mastodon). The real bug behind it is finding 4.
- Early journey failures came from launch fetches racing step 1. That's fixed in the CLI (below).
