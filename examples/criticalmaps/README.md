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
| [fixtures/criticalmaps](fixtures/criticalmaps), [fixtures/sanitize.py](fixtures/sanitize.py) | Sanitized cassettes and their [match.json](fixtures/criticalmaps/match.json) (written by the sanitizer); raw recordings stay in the ignored `fixtures/raw` |

## Run it

Needs Xcode 27 / Swift 6.4, XcodeGen and FlowDeck. From this directory:

```sh
python3 setup.py                                       # fetch + patch + xcodegen (--no-project for headless only)
(cd headless && swift build --triple arm64-apple-ios-macabi)
../../scripts/tca journey run journeys/*.toml           # rung 1, replay: 6 passed, ~1 s each
../../scripts/tca explore --runs 30 --fixtures fixtures/criticalmaps --network replay
../../scripts/tca chaos journeys/mastodon-feed.toml
../../scripts/tca explore --races --runs 30 --fixtures fixtures/criticalmaps --network replay   # 200 +/- 150 ms latency
../../scripts/tca journey run findings/stale-next-page-after-refresh.toml findings/double-send-while-sending.toml   # the race findings
../../scripts/tca fixtures coverage journeys/*.toml --strict   # every request exact, ordered or synthetic

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

## Fixtures: what the matching rules changed

`tca fixtures coverage journeys/*.toml` lists how each request was answered. Before `match.json`, 7 of 26 requests only passed by fallback:

- **The next-ride query never matched its cassette.** It carries the rider's position plus random noise (upstream's `CoordinateObfuscator` uses `Double.random`, a privacy feature, so the harness seed doesn't reach it). Every run asked for different coordinates, and all six launches were answered by the "latest recording for the path" fallback. `tca determinism` couldn't see it, because the coordinates aren't in state. Now `ignore_query` drops `centerLatitude`/`centerLongitude` for `/api/ride`, and the other parameters (month, year, radius) still have to match.
- **The chat post** carries the typed message; the synthetic acknowledgement can't know it. `ignore_body` for `/messages` and `/locations` makes those exact matches.
- **The end of the Mastodon feed** needed a hand-written empty cassette for `max_id=<last id>`, rewritten whenever the recorded pages change. A `pagination` rule (`cursor = max_id`, terminal `[]`) replaces it, so the sanitizer no longer computes the last id.

After: 0 fallbacks, 0 blocked, `--strict` passes, 9 cassettes instead of 10. The chat's three `GET /messages` cassettes stay `ordered` on purpose (a later fetch brings a new message). `PUT__locations_1.json` is unused by the journeys; it answers "Let 30 seconds pass" in `tca explore`.

Re-recording is one command: `tca fixtures record journeys/mastodon-feed.toml --target live --into fixtures/raw --sanitize fixtures/sanitize.py --strict`. It ran once against production in a scratch copy: 8 GETs, the live guard named in the output, the sanitizer run, then the coverage replay clean. Recording `mastodon-feed` alone touches every recorded endpoint.

`journeys/mastodon-feed.toml` pins the requests each step makes (`launch_requests` and per-step `requests`), as written by `tca record` while re-solving it.

## Findings

Each has a minimal journey in [findings/](findings). They fail on upstream `ef2e06d` (headless unless noted), are app bugs rather than harness or fixture artifacts, and weren't fixed here.

1. **Location isn't tracked after allowing access on first launch.** [location-not-tracked-after-allowing.toml](findings/location-not-tracked-after-allowing.toml). On `didChangeAuthorization(.authorizedAlways)`, `MapFeature` calls only `requestLocation()` (one fix). `startUpdatingLocation()` runs only from `locationRequested` when permission was already granted at launch. A new user who allows access shares the position from that moment until they relaunch the app. Reproduces on the UI rung (`gps.updating == false`).
2. **Observation mode never stops (or restarts) the GPS from Settings.** [observation-mode-keeps-gps-on.toml](findings/observation-mode-keeps-gps-on.toml), run with `--target headless-returning`. `SettingsFeature.view(.observationModeChanged)` guards on `isObserving != state.userSettings.isObservationModeEnabled`. The value comes from that same shared setting's publisher, so the guard always returns early (the timeline shows the action arriving on every toggle). No position is posted in observation mode, because `postLocation` checks the setting, but the GPS keeps running. Turning observation mode off never starts updates, which compounds finding 1.
3. **The open chat doesn't show new messages, and they come back as an unread badge.** [chat-does-not-update-while-open.toml](findings/chat-does-not-update-while-open.toml). Found by hand and by `tca explore`, shrunk 16→5 steps: [explore-chat-invariant.toml](findings/explore-chat-invariant.toml). While the chat is open, the poll's `fetchChatMessagesResponse` writes into `AppFeature.State.socialState`, a copy that is never presented, and counts the new messages as unread. The user reading the chat doesn't see them; after closing it, the badge says 1. On the map the badge never updates, because chat is polled only while the sheet is open.
4. **Mastodon stays on the error screen after a successful reload.** [mastodon-error-sticks-after-reload.toml](findings/mastodon-error-sticks-after-reload.toml). Found by hand and by `tca chaos journeys/mastodon-feed.toml`, 8 stranded results. `TootFeedFeature` sets `error` on failure and never clears it, so after one failed load, Reload fetches 40 toots and the screen still shows the error. A failed "load more" is worse: it replaces all 80 loaded toots with the error screen and sets `hasMore = false`. A failed first load shows the "no toots" empty state, not an error. Reproduces on the UI rung with `--pace 1`.
5. **VoiceOver users can't close the upcoming-rides sheet with the escape gesture.** [rides-voiceover-escape.toml](findings/rides-voiceover-escape.toml). `RideEventBottomSheet` sends `RideEvents.Action.dismiss` from `.accessibilityAction(.escape)`. The reducer returns `.none` for it and `AppFeature` doesn't handle it. On the UI rung this journey passes, because of finding 6: the previous sheet's late `onDismiss` closes this one.
6. **A sheet opened right after another closes is closed by the previous sheet's dismissal (UI rung only).** [sheet-closed-by-previous-dismissal.toml](findings/sheet-closed-by-previous-dismissal.toml), found by running the journeys on the simulator (`tca diff ... --targets headless,ui`: `sheet: "social" vs null`). Every sheet's `onDismiss` sends `.whatsNewDismissed` or `.dismissDestination`, both of which set `destination = nil`. They fire when the dismissal animation ends, so a sheet opened within that window is closed again, and TCA reports an `ifLet` action for absent state. The device timeline shows the order: agent `socialButtonTapped`, then app `whatsNewDismissed`, then `dismissDestination`. A person sees the chat refuse to open right after tapping Continue, or settings refuse to reopen right after closing them. With `--pace 1` every journey passes. [Screenshot](recordings/race-chat-closed.png).

7. **Pulling to refresh while the next page loads appends the stale page to the refreshed feed (a race).** [stale-next-page-after-refresh.toml](findings/stale-next-page-after-refresh.toml). Found by `tca chaos --reorder` on a two-step race (Scroll to the end, then Pull to refresh 50 ms later with `no_wait`): with the next-page response held back so it lands last, the feed shows 80 toots instead of the refreshed first page. In order it shows 40. Neither of `TootFeedFeature`'s effects is cancellable and `refresh` doesn't reset `isLoadingNextPage`, so the old `max_id` page is appended to the new list. Against a live feed with new toots that is a gap: the appended page continues from the old list's last toot, not the new one's.
8. **A second tap on Send while a message is posting posts it twice (a race).** [double-send-while-sending.toml](findings/double-send-while-sending.toml). With 300 ms of replay latency, a second "Send chat message" 30 ms into the first POST sends two `POST /messages` with the same text (and two refetches); the journey's race `requests` fail. `ChatFeature`'s `.onCommit` doesn't check `isSending`, the send button shows a spinner but isn't disabled (only hidden for a blank draft), and the draft is cleared only when the POST answers, so the return key or a second tap resends it. This was a read-the-code suspicion before; the race makes it a reproduction.

**Lower confidence (seen in state, not shown in the UI):** a failed chat load renders as "No chat activity" with no retry, because `ChatView` shows the empty state when `messages` is empty, and `.error` has no elements. Chaos counted it as fine because typing is still offered. **From reading the code only:** the send button is hidden with `.opacity(0)` for a blank draft but stays tappable, so an empty message can be sent.

## Results

| Run | Rung | Result |
| --- | --- | --- |
| `tca journey run journeys/*.toml` | headless | 6 passed (0.6–1.1 s each) |
| same | ui | 4 passed; appearance and chat-send fail on finding 6, both pass with `--pace 1` |
| `tca explore --runs 30` (seeds 0 and 1) | headless | 1 real finding (3, twice); 1 harness artifact, fixed (below) |
| `tca chaos` on all 6 journeys | headless | Launch requests faulted too (`GET /locations`, `/messages`, `/api/ride`: 15 runs per journey, 90 in total): all ok. Chat 15/15 ok after launch; Mastodon 8 stranded (finding 4) |
| `tca determinism journeys/mastodon-feed.toml` | headless | 3 runs equal |
| `tca diff findings/sheet-closed-by-previous-dismissal.toml --targets headless,ui` | both | differs after step 2 (finding 6) |
| `tca journey run journeys/*.toml --latency 200 --jitter 150` | headless | 6 passed: the journeys don't depend on instant responses |
| `tca chaos --reorder` on all 6 journeys | headless | nothing to reorder: no step makes two requests to one endpoint, and none races |
| Race journeys (refresh while loading more, load more twice, send twice, close the chat mid-fetch), `--latency 300` and `chaos --reorder` | headless | 1 stale response (finding 7) and a double post (finding 8); load more twice is guarded (the descriptor, like the list, asks once); close mid-fetch fine after one descriptor fix (below) |
| `tca explore --races --runs 30 --steps 30` (seeds 0 and 1, 200 +/- 150 ms) | headless | No new findings: each seed found finding 3 again (x4, x2), which reproduces with every step waited for. Findings 7 and 8 came from the race journeys; the walks rarely type, send and tap Send again within one POST |

**Triaged as artifacts:**
- Racing "Close chat and Mastodon" against "Open chat and Mastodon" left the open receipt `running` forever (**stuck**): its completion predicate returned `running` whenever the social sheet wasn't presented, including after it closed. A descriptor bug exposed by the race, not an app bug; the predicate now reports `succeeded` once the sheet is gone.
- `tca explore --races` reported finding 3's invariant with a `no_wait` step. Shrinking kept the timing because its replay checks stopped at the last step, while the poll's `GET /messages` (about 250 ms of replay latency) lands after it. Shrink replays now wait for quiet like `journey run`, and drop timing the finding doesn't need: it shrinks to Close What's New, Open chat, Let a minute pass, with no race.
- An invariant "no location is posted in observation mode" fired flakily in explore. It compared network log sequence numbers, which are assigned when a request completes, so a PUT started before the toggle could complete after it. It was removed: the harness can't attribute a request to the action that started it.
- Chaos counts Mastodon's first-load failure as stranded because the retry is a different operation (Reload) from the step that failed (Show Mastodon). The real bug behind it is finding 4.
- Early journey failures came from launch fetches racing step 1. That's fixed in the CLI (below).
- With launch faults, the first chaos pass flagged two `slow` (2 s delay) results: "Show upcoming rides" not offered after a slow `GET /api/ride`, and the open-chat invariant after a slow launch `GET /messages`. Both came from the harness calling the app quiet while a request was still in flight (the request log only records finished requests), so the journey went on before the response landed. The `network` snapshot now counts `pending` requests and runs wait for them; both pass. The chat one shows finding 3's mechanism (a response written into the unpresented `socialState` copy), which a person could hit by opening the chat while the launch fetch is slow.
- One chaos run failed to launch with "Address already in use": a free port taken between the CLI picking it and the app binding it. Launches on `auto` ports now retry on a new port.
