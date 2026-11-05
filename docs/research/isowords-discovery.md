# isowords: discovery and nested-reducer integration

Research date: October 24, 2026. Read-only investigation of Point-Free's actual
isowords source at `c727d3a7c49cf0c98f2fa4f24c562f81e30165f7`. The existing local checkout had unrelated edits; this research did not modify it.

## Actual architecture and dependencies

The root package declares public TCA from 1.12.0 and the existing local lockfile pins
TCA **1.13.0** and CasePaths **1.5.4**. No TCA 2 migration is required for this
experiment. The root, Home, Game, and Settings features use `@Reducer` and
`@ObservableState`. Root State is Equatable, not Codable.

Sources: [manifest](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Package.swift),
[root feature](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/AppFeature/AppView.swift).

A concrete routing chain is:

- `AppReducer.State.home` + `AppReducer.Action.home(Home.Action)`.
- `Home.State.destination: Home.Destination.State?` with `@Presents`.
- `Home.Action.destination(PresentationAction<Home.Destination.Action>)`.
- Destination has cases including `.settings(Settings)`, `.solo(Solo)`,
  `.dailyChallenge(DailyChallengeReducer)`, and `.multiplayer(Multiplayer)`.
- Home's `.settingsButtonTapped` constructs `.settings(Settings.State())`.
- Settings composes a nested Stats reducer with `Scope(state: \.stats, action:
  \.stats)`.

Sources: [Home](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/HomeFeature/Home.swift),
[Settings](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/SettingsFeature/Settings.swift).

## Discovery already available from public dependencies

TCA 1.13's `@Reducer` applies `@CasePathable` to nested Action enums. CasePaths
1.5.4's macro generates `AllCasePaths: Sequence` and `CasePathIterable` conformance.
Therefore enumerating the action case paths is already available without adding
an annotation to every action case.

Moreover, `PartialCaseKeyPath<Action>` has `callAsFunction(_ value: Any) -> Action?`.
It performs a checked payload-type match and embeds a matching value in the actual
enum. Iterating action case paths and attempting to embed `()` can discover and
construct no-payload actions. Explicitly known primitive and enum payload values
can also be embedded. This avoids creating a handwritten execution closure for
every zero-argument action.

Sources: [TCA 1.13 ReducerMacro](https://github.com/pointfreeco/swift-composable-architecture/blob/1.13.0/Sources/ComposableArchitectureMacros/ReducerMacro.swift),
[CasePaths 1.5.4 macro](https://github.com/pointfreeco/swift-case-paths/blob/1.5.4/Sources/CasePathsMacros/CasePathableMacro.swift),
[CasePathable and erased embedding](https://github.com/pointfreeco/swift-case-paths/blob/1.5.4/Sources/CasePaths/CasePathable.swift).

Limits: the resulting catalog does not itself supply meaningful argument schemas,
current allowed IDs, preconditions, operation completion, or permission to invoke
internal effect responses. Case names are not a business interface. isowords has
response/result actions, lifecycle actions, callbacks, gesture-state values, and
purchase actions in the same enums. The catalog must distinguish discoverable
cases from executable operations. The newer `caseName(for:)` helper found in some
local CasePaths caches should not be assumed to exist in the pinned 1.5.4 macro.

## A promising deeper runtime probe (not compile-verified here)

Public `Case<Payload>` can potentially conform to a harness-owned protocol exposing
`Payload.self`. `type(of: erasedCasePath).valueType` identifies its `Case<Payload>`
metatype, allowing the harness to recover a payload metatype, recursively enumerate
case-path-iterable child enums, construct child payloads, and embed them into the
parent action. This could generalize nested action construction without per-case
source generation. It needs a real compiler/runtime test before claiming support.

A specific wrapper exception is already visible: TCA 1.13 `PresentationAction` is
CasePathable, but its hand-written `AllCasePaths` is not Sequence. A generic
PresentationAction wrapper adapter can expose `.dismiss` and `.presented` once for
all features rather than rewriting those wrappers per feature.

Source: [TCA 1.13 PresentationAction](https://github.com/pointfreeco/swift-composable-architecture/blob/1.13.0/Sources/ComposableArchitecture/Reducer/Reducers/PresentationReducer.swift).

## Nested-state routing still needs structural relationships

Action enums alone do not establish which state property belongs to which child
reducer, whether a destination is active, or which element ID is valid. Those
relationships are expressed by `Scope`, `ifLet`, destination reducer cases, and
`forEach` in the app's reducer composition.

For ordinary scoped children, compose the declared state key path and action case
path. For presented children, gate discovery on the current non-nil state and
selected destination case; embed actions through `.presented` and that case.
Generate or register the relationship once, then rebuild active catalogs from
current state. Dispatch must revalidate the path and current feature instance.
A cached closure into a dismissed/replaced child is not sufficient.

For collections, isowords' `PastGames` has `IdentifiedArrayOf<PastGame.State>` and
`IdentifiedActionOf<PastGame>`, composed with `.forEach(\.pastGames, action:
\.pastGames)`. Catalog element targets should use actual stable IDs, never array
positions or type names.

Source: [PastGames](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/MultiplayerFeature/PastGamesView.swift).

A SwiftSyntax generator can derive common relationships directly from composition
expressions and generate typed registration code. It must report unsupported
custom composition, rather than silently guessing. An attached macro is another
option for generating typed field/action descriptors inside private lexical
contexts. Both approaches improve discovery; neither automatically infers all
business semantics. Runtime value reflection is useful for observations but does
not provide a general public mechanism for turning strings into writable Swift
key paths.

## Arbitrary state and binding operations

Settings State includes alerts, StoreKit results/products, optional platform
notification settings, nested Stats state, and a Codable UserSettings value. Game
State includes a puzzle, selection, moves, timers, presentation, and platform
behavior. Requiring all app state to become Codable would be intrusive.

Instead, normalize supported observation values to a bounded JSON tree, preserve
case/type information, and represent opaque/unhandled values explicitly. Offer
app overrides for redaction and domain-specific projections. A macro/generated
projection can avoid dumping TCA backing storage. Reflection should be bounded by
depth, collection length, and cycle detection for reference values.

Settings' UI writes through normal bindings, for example
`$store.userSettings.enableHaptics`, `enableGyroMotion`, `enableReducedAnimation`,
`musicVolume`, `soundEffectsVolume`, and `colorScheme`. The correct harness write
path is a typed `Settings.Action.binding(.set(keyPath, value))`, composed through
the same parent actions. TCA 1.13's observation binding extension provides this
for ordinary ObservableState fields. Writing projected state directly would skip
Settings' onChange effects such as audio updates and style application.

Sources: [UserSettings](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/UserSettingsClient/UserSettings.swift),
[Accessibility UI](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/SettingsFeature/AccessibilitySettingsView.swift),
[Sounds UI](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/SettingsFeature/SoundsSettingsView.swift),
[TCA 1.13 binding implementation](https://github.com/pointfreeco/swift-composable-architecture/blob/1.13.0/Sources/ComposableArchitecture/Observation/Binding%2BObservation.swift).

## Recommended first integration and next progression

Start with real App/Home/Settings reducers, not rewritten lookalikes. Discover
Home navigation and conditional Settings operations, then dispatch accessibility,
color, and volume changes through actual binding actions. This tests a real
non-Codable state tree, nested presentation, bindings, and side effects.

Then add a collection feature and exercise removed/replaced elements. Finally add
Game cube operations: its `.tap(UIGestureRecognizer.State, IndexedCubeFace?)` and
`.pan(UIGestureRecognizer.State, PanData?)` need explicit codecs and state-derived
playable-target providers; `.submitButtonTapped(reaction:)` needs current-game
availability. A concrete cube face is not safely inferred from an enum name.

Source: [GameCore](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Sources/GameCore/GameCore.swift).

The repository already has miniature preview applications, mock dependencies, and
a trailer feature that sends real game actions. These are useful first-party
precedents for deterministic fixtures and controlled app hosts, not evidence that
an automatic harness already exists.

Sources: [Settings preview](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/App/Previews/SettingsPreview/SettingsPreviewApp.swift),
[repository README](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/README.md).

## Source distribution note

isowords' repository license is not MIT/Apache: it describes an educational
permitted purpose and restrictions on distributing the entire software or exact
replicas. Preserve upstream attribution and the license in local integration
checkouts. A reproducible patch/setup script or integration example referencing
upstream is preferable to copying the whole game into this library's repository.
This is a factual description of the source license, not a legal determination of
how a particular distribution may be used.

Source: [isowords license](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/LICENSE.md).
