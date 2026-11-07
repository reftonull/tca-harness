# Adopting the harness in a large app

This is a plan for a large TCA 1.x app that is mostly server-driven: most screens load something over REST, and some screens are vanilla SwiftUI. It is ordered so that each step pays for itself before the next, and nothing requires writing tests up front. The costs quoted come from integrating [Critical Maps](../examples/criticalmaps/README.md), a production app with about 20 features and a live backend, and from the [Shelf](../examples/shelf/README.md) example.

## What it cost on a real app

| | Critical Maps |
| --- | --- |
| Changes to the app | 2 small patches: the root store gets `.harnessTimeline()` and keeps the attachment; the package manifest adds Mac Catalyst for the headless host. Reducers and views untouched |
| Harness code | One file of about 550 lines: descriptors for 5 screen areas, invariants, run dependencies (network routing, fixed location, isolated storage) |
| Headless host | About 70 lines, mostly replaying what views send on appear |
| Fixtures | 9 cassettes and one `match.json`, recorded with 8 read-only GETs and sanitized by a script |
| Result | 6 journeys at about 1 s each, and 6 real bugs found by explore, chaos and the headless-vs-simulator diff |

## Step 1: attach and look around (a day)

Attach the harness to the root store. It does nothing unless launched with `TCA_HARNESS=1`, and the listener is compiled out of release builds.

```swift
let store = Store(initialState: AppFeature.State()) { AppFeature().harnessTimeline() }
let harness = store.harness(AppFeature.self)
try harness.startIfEnabled()
```

Annotate features with `@HarnessFeature`. Actions named `…ButtonTapped` are exposed automatically, so an agent can already walk much of the app with `tca ls` / `tca do`, and `tca devtools` shows every action with diffs. The generic oracles are already on: crashes, TCA's own runtime warnings (an action sent to a dismissed child, an `unimplemented` dependency) and stuck effects.

Where it gets harder in a real app:

- **Internal state.** Explicit descriptors can't use key paths to internal properties from another module. Critical Maps read three of them by reflection.
- **State the views own.** Toggles bound straight to `@Shared` from a view, map state written by `MKMapView`, and focus have no action. Expose a binding action that writes the same storage, or accept that only the simulator rung sees it.
- **Payload actions.** Actions with arguments need `@HarnessOperation` or an explicit operation with a `@HarnessSchema` input. Operations can also build their action from what's on screen (`action: { state in .select(state.ride) }`).

### How much of the app can an agent reach?

`tca exposure` answers that per feature path. The descriptor's catalog lists every feature it can mount, so screens no run has reached show up too. Each feature lists the operations it declares, how many dispatches ran each, and the action cases no operation sends, with why. `@HarnessFeature` fills that list itself (`ignored`, `unannotated`, `binding`, `unsupported payload`, `multiple payloads`). Explicit descriptors declare their own with `.unexposed("case", reason: "...")`. On day one, run it against the app (`tca exposure --port 8767`) and read the unexposed list as a to-do list. On a hundred screens, sort it by reason: `unannotated` and `unsupported payload` are decisions nobody has made yet; `ignored` is a decision someone made.

Critical Maps, with its six journeys (`tca exposure --journeys 'journeys/*.toml'`, trimmed):

```text
exposure: 13 feature(s) from 6 journey run(s)

  root  Critical Maps
    OPERATION       LABEL                                                    EXERCISED
    openSocial      Open chat and Mastodon                                   2
    openSettings    Open settings                                            3
    showRides       Show upcoming rides                                      1
    tracking        Change map tracking (follow, follow with heading, free)  .
    shareRide       Share the next ride                                      .
    closeShare      Close the share sheet                                    .
    halfway         Let 30 seconds pass (the app posts your location)        .
    fullCycle       Let a minute pass (the app refreshes riders)             .
    swipeDownRides  Swipe the upcoming rides down                            1
    unexposed (lifecycle): onAppear, onDisappear, didBecomeActive
    unexposed (effect): fetchLocations, postLocation, fetchChatMessages, nextRide
    unexposed (response): fetchLocationsResponse, postLocationResponse, fetchChatMessagesResponse
    unexposed (sheet onDismiss): dismissEventList, dismissDestination, whatsNewDismissed
    unexposed (binding): binding
    unexposed (opens Apple Maps): map.routeToEvent
    unexposed (map gesture): map.updateCenterRegion
  ...
  root/settings/privacyZones  Privacy zones  (not reached)
    OPERATION  LABEL                          EXERCISED
    toggle     Turn privacy zones on or off   .
    toggleMap  Show or hide zones on the map  .
    unexposed (needs a map drag): addZoneButtonTapped, destination
    unexposed (needs a zone): deleteZone, toggleZoneActive, selectZone, alert
    unexposed (binding): binding
  ...
  root/whatsNew  What's New
    OPERATION  LABEL             EXERCISED
    continue   Continue          6
    close      Close What's New  .

totals: 12 of 13 feature(s) reached, 53 exposed operation(s), 21 exercised (39.6%); 38 unexposed action(s): effect 10, response 7, lifecycle 6, needs a zone 4, sheet onDismiss 3, binding 2, system file picker 2, needs a map drag 2, opens Apple Maps 1, map gesture 1
not reached (1): root/settings/privacyZones
```

What that shows, and what to do about it:

- **Worth exposing: sheet dismissal.** Each sheet's `onDismiss` sends `whatsNewDismissed`, `dismissDestination` or `dismissEventList`. The headless host never does, so on headless, Close on What's New closes the sheet without marking it seen; in the app, `whatsNewDismissed` saves `lastSeenWhatsNewVersion`. That is logic only the UI rung runs. The host should send the `onDismiss` action when a sheet's destination goes away, as it already sends `onAppear`. Only Upcoming rides offers a swipe-down: adding one to What's New, Social and Settings gives `explore --races` the dismissal paths that [finding 6](../examples/criticalmaps/README.md) races on.
- **Worth exposing: privacy zones.** The screen is in the catalog but no journey opens it, and creating, activating or deleting a zone isn't reachable at all, because creation takes a map drag (`CreateZoneFeature.setMapCenter`). An "Add a zone here" operation that sends `setMapCenter` with the fixed location and then `createZone` would make the rule that matters testable: no location is posted from inside an active zone.
- **Worth a journey: exposed but never run.** 32 of 53 operations, among them the app's core loop (`halfway` posts your location, `fullCycle` refetches riders), map tracking, the share sheet, observation mode and the chat's Dismiss error. Explore reaches most of them at random; a journey pins the important ones.
- **Fine to leave:** `lifecycle`, `effect` and `response` (23 cases) are sent by views on appear or by the app's own effects; the host sends the lifecycle ones and the time operations drive the timer. The GPX importer needs the system file picker. Route to event calls `MKMapItem.openInMaps` directly rather than through a dependency, so it can't be recorded like the links are. `updateCenterRegion` comes from `MKMapView`. The two `binding` cases are the rides sheet's detent and the privacy-zone toggles, which are exposed through their actions.

## Step 2: route the network (a day per backend)

Route the app's `URLSession` through the harness. With one API client dependency this is one override.

```swift
$0.urlSession = URLSession(configuration: HarnessNetwork.configure(.ephemeral))
HarnessNetwork.install()                                  // also covers URLSession.shared
HarnessNetwork.shared.liveGuard = .readOnly(hosts: ["api.example.com"])   // before recording from a real backend
```

From then on every harness run blocks the network unless told otherwise. Record fixtures by running journeys against a backend (`tca fixtures record journeys/*.toml --target live --sanitize sanitize.py`), with the live guard refusing anything but reads. Then write `match.json` for what varies between runs:

- `path_templates` for ids: `/books/{id}` turned Shelf's 39 per-id cassettes into 5.
- `ignore_query` for volatile parameters: Critical Maps adds random noise to coordinates, so its ride query never matched exactly until `centerLatitude`/`centerLongitude` were ignored.
- `ignore_body` for writes whose acknowledgement doesn't depend on the body.
- `pagination` with a terminal page, instead of hand-written empty pages.

`tca fixtures coverage journeys/*.toml --strict` fails whenever a request was blocked or only matched by fallback, which is the signal a fixture is missing or a rule is wrong. Commit the sanitized cassettes, never the raw ones.

## Step 3: invariants on the features that matter (an hour each)

Rules a user would notice if broken: a badge that disagrees with its list, duplicate rows, a spinner with no request in flight, a total that doesn't match its items. They live on the descriptor next to the feature, are checked after every action, and turn every journey and every random walk into a test.

```swift
.invariant("unread badge matches the list") { $0.unreadCount == $0.items.filter { !$0.isRead }.count }
```

## Step 4: journeys for the core flows (recorded, not written)

Have an agent do the flow with `tca do` while `tca record` captures it. A recorded journey pins the steps by label, the checks on what the user sees, and the requests each step makes (`requests = ["GET /cards", "POST /cards/{id}/lock"]`), which is the contract a server-driven screen most often breaks. When a flow changes, the run fails with the current screen and the goal, and an agent re-solves it.

To pick the flows, and to see what is still uncovered once they exist, run `tca exposure --journeys 'journeys/*.toml' --reports explore.jsonl`. On Shelf the eight journeys exercise 17 of 26 operations (65%), and a 20-run explore report brings that to 23 (88%). The three left are Retry buttons that only appear after a failed load. `tca chaos` checks they are offered but doesn't press them, so each needs a journey with a `[[faults]]` entry that taps Retry. `--min-exercised 80` makes it a gate.

## Step 5: let the patterns find bugs (headless)

The headless host runs the real reducers with no UI. Modules that import UIKit build for Mac Catalyst. The host must send what views send on appear. At about 70 actions per second:

- `tca explore` walks random operations with generated arguments and shrinks each finding to a minimal journey.
- `tca chaos` fails each request in turn (including at launch) and flags the user being stranded.
- `tca determinism` and `tca diff` (headless vs simulator) find hidden nondeterminism and logic that only runs when views exist.

On Critical Maps these found a chat that never shows new messages while open, location tracking that never starts after allowing access, a Mastodon error screen that sticks after a successful reload, a settings toggle that never stops the GPS, a broken accessibility escape, and a sheet closed by the previous sheet's late dismissal.

## Vanilla SwiftUI screens

Screens built on `@Observable` models use the same descriptors. Mount them inside the TCA app with `.model("name", { $0.model }, descriptor:)`, or wrap them in `Hosted<Model>`. With `Hosted`, the store owns their lifecycle: calls run as effects, are cancelled on dismissal and appear in the timeline. See [Vanilla SwiftUI models](../TCAHarnessTCA1/README.md#vanilla-swiftui-models).

## Rules worth keeping

- Don't record from a production backend without `liveGuard`, and don't commit raw recordings.
- Seed what varies (`harnessDeterministic()`), isolate storage per run, and fix the location and clock, so runs are reproducible.
- Check what the user sees, not internals. Labels and published state change less often than code.
- Keep the generic oracles on everywhere. Most of the Critical Maps findings came from invariants, issues and stuck effects, not from journey checks.
