import ApiClient
import AppFeature
import ChatFeature
import ComposableArchitecture
import ComposableCoreLocation
import FeedbackGeneratorClient
import Foundation
import MapFeature
import MastodonFeedFeature
import NextRideFeature
import SettingsFeature
import SharedKeys
import SharedModels
import SocialFeature
import TCAHarnessTCA1
import UIApplicationClient

/// Everything the TCA harness sees of Critical Maps, attached to the app's original root store.
///
/// Upstream reducers and views are unchanged. This file adds:
/// - `prepare(_:)`: harness-run dependencies. The network goes through `HarnessNetwork` with a
///   read-only live guard, location is a fixed coordinate, storage is isolated, outside effects
///   (opening URLs, icons, haptics) are recorded instead of performed. It does nothing unless the
///   process was launched with `TCA_HARNESS=1` (the app) or by the headless host.
/// - `descriptor`: what a user sees on each screen and the operations they can perform, by label.
/// - invariants a user would notice when broken.
@MainActor
public enum CriticalMapsHarness {
  /// Hosts the app may read from while recording fixtures. Nothing else, and no method other than
  /// GET/HEAD, reaches the real network in `record` or `live` mode.
  public nonisolated static let readOnlyHosts: Set<String> = ["criticalmaps.net", "criticalmass.in", "mastodon.social"]

  /// The fixed position harness runs report: Alexanderplatz, Berlin. Never the device's location.
  public nonisolated static let coordinate = (latitude: 52.5219, longitude: 13.4132)

  public static func attach(to store: StoreOf<AppFeature>, timeline: HarnessTimeline? = .shared)
    -> StoreHarness<AppFeature.State, AppFeature.Action> {
    store.harness(descriptor: descriptor, timeline: timeline)
  }

  /// Harness-run dependencies. A no-op unless `TCA_HARNESS=1` or `headless`.
  public nonisolated static func prepare(_ values: inout DependencyValues, headless: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment) {
    guard headless || environment["TCA_HARNESS"] == "1" else { return }
    #if DEBUG
    // Network: replay/record/live/block per run. The guard is set in-process; `tca` can switch
    // the mode over the wire but cannot remove the guard.
    let network = HarnessNetwork.shared
    network.liveGuard = .readOnly(hosts: readOnlyHosts)
    if (environment["TCA_HARNESS_NETWORK"] ?? "").isEmpty { network.mode = .block }
    HarnessNetwork.install()  // URLSession.shared: MastodonKit's client
    values.urlSession = URLSession(configuration: HarnessNetwork.configure(.ephemeral))  // NetworkDispatcher
    #endif
    values.harnessDeterministic()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    values.calendar = calendar
    values.timeZone = .gmt
    values.locale = Locale(identifier: "en_US_POSIX")
    values.appVersion = "4.10.1"  // MARKETING_VERSION of the pinned app target
    // The poll timer would post the location after 30 s and refetch after 60 s at an arbitrary step.
    // Runs advance it explicitly instead ("Let 30 seconds pass", "Let a minute pass").
    values.serverConfiguration.pollIntervalSeconds = 24 * 60 * 60
    values.locationManager = HarnessLocation.shared.manager(environment: environment)
    values.apiService = HarnessPosting.watching(values.apiService)
    values.uiApplicationClient = HarnessApplication.client(headless: headless)
    values.feedbackGenerator = .noop
    // Every run starts as a fresh install, and nothing a run saves reaches the next one.
    let suite = "tca-harness.criticalmaps"
    UserDefaults().removePersistentDomain(forName: suite)
    values.defaultAppStorage = UserDefaults(suiteName: suite)!
    values.defaultFileStorage = .inMemory
  }
}

// MARK: - Descriptors

extension CriticalMapsHarness {
  typealias Destination = AppFeature.Destination.State

  public static var descriptor: FeatureDescriptor<AppFeature.State, AppFeature.Action> {
    let noSheet: (AppFeature.State) -> Bool = { destination($0) == nil }
    return FeatureDescriptor<AppFeature.State, AppFeature.Action>("Critical Maps", observation: observe)
      // Onboarding
      .child("whatsNew", state: { if case let .whatsNew(s)? = destination($0) { s } else { nil } },
        action: { .destination(.presented(.whatsNew($0))) }, descriptor: whatsNew)
      // Map screen
      .operation("openSocial", label: "Open chat and Mastodon", action: .socialButtonTapped, available: noSheet,
        completion: { state in
          // Closed before the chat answered (a race): nothing is loading on the sheet's behalf any more.
          guard case let .social(social)? = destination(state) else { return .succeeded }
          return chatLoaded(social)
        })
      .operation("openSettings", label: "Open settings", action: .settingsButtonTapped, available: noSheet)
      // Swiping a sheet down sets its item binding to nil (`.destination(.dismiss)`); the headless host
      // then sends the sheet's `onDismiss`, as SwiftUI does once the sheet is gone.
      .operation("swipeDownWhatsNew", label: "Swipe down to close What's New", action: .destination(.dismiss),
        available: { if case .whatsNew? = destination($0) { true } else { false } })
      .operation("swipeDownSocial", label: "Swipe down to close chat and Mastodon", action: .destination(.dismiss),
        available: { if case .social? = destination($0) { true } else { false } })
      .operation("swipeDownSettings", label: "Swipe down to close settings", action: .destination(.dismiss),
        available: { if case .settings? = destination($0) { true } else { false } })
      .operation("showRides", label: "Show upcoming rides", action: .didTapNextRideOverlayButton,
        available: { noSheet($0) && nextRideBanner($0) })
      .operation("tracking", label: "Change map tracking (follow, follow with heading, free)",
        action: .map(.userTracking(.nextTrackingMode)), available: noSheet)
      .operation("shareRide", label: "Share the next ride", action: .map(.showShareSheet(true)),
        available: { noSheet($0) && $0.mapFeatureState.nextRide != nil && !$0.mapFeatureState.presentShareSheet })
      .operation("closeShare", label: "Close the share sheet", action: .map(.showShareSheet(false)),
        available: { $0.mapFeatureState.presentShareSheet })
      // Time. The app's poll timer sends these; a run sends them instead of waiting.
      .operation("halfway", label: "Let 30 seconds pass (the app posts your location)",
        action: .requestTimer(.halfwayPoint), available: { $0.requestTimer.isTimerActive })
      .operation("fullCycle", label: "Let a minute pass (the app refreshes riders)",
        action: .requestTimer(.fullCycle), available: { $0.requestTimer.isTimerActive })
      // Location. The fake reports one fix when updates start; a moving rider's GPS reports again
      // every 200 m (MapFeature's distance filter). This sends what the location manager would.
      .operation("gpsFix", label: "The GPS reports your position again", available: { _ in HarnessLocation.shared.isUpdating }) { _ in
        .map(.locationManager(.didUpdateLocations([HarnessLocation.shared.location])))
      }
      .child("social", state: { if case let .social(s)? = destination($0) { s } else { nil } },
        action: { .destination(.presented(.social($0))) }, descriptor: social)
      .child("settings", state: { if case let .settings(s)? = destination($0) { s } else { nil } },
        action: { .destination(.presented(.settings($0))) }, descriptor: settings)
      .operation("swipeDownRides", label: "Swipe down to close the upcoming rides", action: .destination(.dismiss),
        available: { if case .rideEvents? = destination($0) { true } else { false } })
      .child("rides", state: { if case let .rideEvents(s)? = destination($0) { s } else { nil } },
        action: { .destination(.presented(.rideEvents($0))) }, descriptor: rides)
      // What no operation sends, for `tca exposure` (docs/adopting.md has the triage).
      .unexposed("onAppear", reason: "lifecycle").unexposed("onDisappear", reason: "lifecycle")
      .unexposed("didBecomeActive", reason: "lifecycle")
      .unexposed("fetchLocations", reason: "effect").unexposed("postLocation", reason: "effect")
      .unexposed("fetchChatMessages", reason: "effect").unexposed("nextRide", reason: "effect")
      .unexposed("fetchLocationsResponse", reason: "response").unexposed("postLocationResponse", reason: "response")
      .unexposed("fetchChatMessagesResponse", reason: "response")
      // Each sheet's `onDismiss` sends one of these once the sheet is gone; the headless host does too.
      .unexposed("dismissEventList", reason: "lifecycle").unexposed("dismissDestination", reason: "lifecycle")
      .unexposed("whatsNewDismissed", reason: "lifecycle")
      .unexposed("binding", reason: "binding")  // eventListPresentation: the rides sheet's detent, dragged
      .unexposed("map.routeToEvent", reason: "opens Apple Maps")
      .unexposed("map.updateCenterRegion", reason: "map gesture")
      // The map draws `mapFeatureState.riderLocations`. AppFeature's own copy is never shown, and a
      // failed refresh empties it while the map keeps the last positions, so only a successful fetch
      // (a non-empty copy) is compared.
      .invariant("the map shows the riders that were fetched") {
        $0.riderLocations.isEmpty || $0.riderLocations == $0.mapFeatureState.riderLocations
      }
      .invariant("no rider appears twice") { Set($0.mapFeatureState.riderLocations.map(\.id)).count == $0.mapFeatureState.riderLocations.count }
      .invariant("unread badge never exceeds the messages") {
        Int($0.chatMessageBadgeCount) <= ($0.socialState.chatFeatureState.chatMessages.elements?.count ?? 0)
      }
      // Checked against what the app handed its API client, at the moment it did: a request's
      // completion order can't attribute it to the step that started it, the call can.
      .invariant("no location is posted from inside an active privacy zone") { _ in HarnessPosting.shared.fromInsideZone == 0 }
      .invariant("the open chat shows the messages the app fetched") { state in
        guard case let .social(social)? = destination(state), social.socialControl == .chat,
          case .results = social.chatFeatureState.chatMessages else { return true }
        let fetched = Set((state.socialState.chatFeatureState.chatMessages.elements ?? []).map(\.id))
        return fetched.isSubset(of: Set(social.chatFeatureState.messages.map(\.id)))
      }
  }

  static var whatsNew: FeatureDescriptor<WhatsNew.State, WhatsNew.Action> {
    FeatureDescriptor<WhatsNew.State, WhatsNew.Action>("What's New", observation: { _ in .object([:]) })
      .operation("continue", label: "Continue", action: .continueButtonTapped)
      .operation("close", label: "Close What's New", action: .closeButtonTapped)
  }

  /// The chat tab shows a spinner until its fetch answers.
  static func chatLoaded(_ state: SocialFeature.State) -> HarnessOperationStatus {
    if case .loading = state.chatFeatureState.chatMessages { return .running }
    return .succeeded
  }

  static var social: FeatureDescriptor<SocialFeature.State, SocialFeature.Action> {
    let chat = FeatureDescriptor<ChatFeature.State, ChatFeature.Action>("Chat", observation: observeChat)
      .operation("type", label: "Type a chat message", arguments: String.self,
        action: { .chatInput(.messageChanged(NSAttributedString(string: $0))) }, available: { $0.alert == nil })
      // The send button only fades out when the message is blank; it stays tappable while sending.
      .operation("send", label: "Send chat message", action: .chatInput(.onCommit),
        available: { $0.alert == nil && !$0.chatInputState.isSendButtonDisabled },
        completion: { $0.chatInputState.isSending ? .running : .succeeded })
      .operation("dismissAlert", label: "Dismiss the error", action: .alert(.dismiss), available: { $0.alert != nil })
      .unexposed("onAppear", reason: "lifecycle").unexposed("fetchChatMessages", reason: "effect")
      .unexposed("fetchChatMessagesResponse", reason: "response").unexposed("chatInputResponse", reason: "response")
      .invariant("no message is listed twice") { Set($0.messages.map(\.id)).count == $0.messages.count }
    let toot = FeatureDescriptor<TootFeature.State, TootFeature.Action>("Toot", observation: observeToot)
      .operation("open", label: "Open toot in the browser", action: .openTweet)
      .operation("openAuthor", label: "Open the author's profile", action: .openUser)
    let mastodon = FeatureDescriptor<TootFeedFeature.State, TootFeedFeature.Action>("Mastodon", observation: observeMastodon)
      .operation("refresh", label: "Pull to refresh", action: .refresh,
        available: { feedScreen($0) == "list" || feedScreen($0) == "error" }, completion: { $0.isLoading ? .running : .succeeded })
      .operation("reload", label: "Reload", action: .fetchData,
        available: { ["empty", "error"].contains(feedScreen($0)) }, completion: { $0.isLoading ? .running : .succeeded })
      // The list asks for the next page when its last row appears and more pages are expected.
      .operation("loadMore", label: "Scroll to the end of the feed", action: .loadNextPage,
        available: { feedScreen($0) == "list" && $0.hasMore && !$0.isLoadingNextPage },
        completion: { $0.isLoadingNextPage ? .running : .succeeded })
      .identified("toots", state: \.toots, action: \.toot, descriptor: toot).covering("toot")
      .unexposed("onAppear", reason: "lifecycle")
      .unexposed("fetchDataResponse", reason: "response").unexposed("fetchNextPageResponse", reason: "response")
      .invariant("no toot is listed twice") { Set($0.toots.map(\.uri)).count == $0.toots.count }
    return FeatureDescriptor<SocialFeature.State, SocialFeature.Action>("Social", observation: observeSocial)
      .operation("showMastodon", label: "Show Mastodon", action: .binding(.set(\.socialControl, .toots)),
        available: { $0.socialControl == .chat }, completion: { $0.mastodonFeedState.isLoading ? .running : .succeeded })
      .operation("showChat", label: "Show chat", action: .binding(.set(\.socialControl, .chat)),
        available: { $0.socialControl == .toots }, completion: chatLoaded)
      .operation("close", label: "Close chat and Mastodon", action: .dismiss)
      .child("chat", state: { $0.socialControl == .chat ? $0.chatFeatureState : nil }, action: { .chat($0) }, descriptor: chat)
      .child("mastodon", state: { $0.socialControl == .toots ? $0.mastodonFeedState : nil }, action: { .toots($0) }, descriptor: mastodon)
  }

  static var settings: FeatureDescriptor<SettingsFeature.State, SettingsFeature.Action> {
    typealias S = SettingsFeature.State
    let top: (S) -> Bool = { settingsDestination($0) == nil }
    func toggle(_ id: String, _ on: String, _ off: String, _ field: WritableKeyPath<S, Bool> & Sendable)
      -> [(String, String, SettingsFeature.Action, (S) -> Bool)] {
      [(id + "On", on, .binding(.set(field, true)), { top($0) && !$0[keyPath: field] }),
       (id + "Off", off, .binding(.set(field, false)), { top($0) && $0[keyPath: field] })]
    }
    var descriptor = FeatureDescriptor<S, SettingsFeature.Action>("Settings", observation: observeSettings)
    // Rows bound straight to the shared user settings in the view. A binding action writes the same
    // `@Shared(.userSettings)` value the toggle writes.
    for (id, label, action, available) in toggle("observation", "Turn observation mode on", "Turn observation mode off", \.userSettings.isObservationModeEnabled)
      + toggle("info", "Show the info overlay", "Hide the info overlay", \.userSettings.showInfoViewEnabled)
      + toggle("highlight", "Highlight active riders", "Stop highlighting active riders", \.userSettings.highlightActiveRiders) {
      descriptor = descriptor.operation(id, label: label, action: action, available: available)
    }
    let links: [(String, String, SettingsFeature.Action.ViewAction)] = [
      ("website", "Open the Critical Maps website", .infoSectionRowTapped(.website)),
      ("mastodonLink", "Open Critical Maps on Mastodon", .infoSectionRowTapped(.mastodon)),
      ("privacy", "Open the privacy policy", .infoSectionRowTapped(.privacy)),
      ("github", "Open the GitHub repository", .supportSectionRowTapped(.github)),
      ("criticalmass", "Open criticalmass.in", .supportSectionRowTapped(.criticalMassDotIn)),
      ("crowdin", "Help translate on Crowdin", .supportSectionRowTapped(.crowdin)),
    ]
    for (id, label, action) in links { descriptor = descriptor.operation(id, label: label, action: .view(action), available: top) }
    return descriptor
      .operation("privacyZones", label: "Open privacy zones", action: .view(.privacyZonesRowTapped), available: top)
      .operation("rideEvents", label: "Open event settings", action: .view(.rideEventSettingsRowTapped), available: top)
      .operation("appearance", label: "Open appearance", action: .view(.appearanceSettingsRowTapped), available: top)
      .operation("guide", label: "Open the rules guide", action: .view(.guideRowTapped), available: top)
      .operation("acknowledgements", label: "Open acknowledgements", action: .view(.acknowledgementsRowTapped), available: top)
      .operation("removeRoute", label: "Remove the GPX route", action: .view(.gpxRouteRemoved),
        available: { top($0) && $0.userSettings.gpxRoute != nil })
      .operation("close", label: "Close settings", action: .view(.dismiss), available: top)
      .operation("back", label: "Back to settings", action: .destination(.dismiss), available: { !top($0) })
      .unexposed("view.onAppear", reason: "lifecycle")
      .unexposed("view.gpxImportButtonTapped", reason: "system file picker")
      .unexposed("view.gpxFileSelected", reason: "system file picker")
      .unexposed("gpxRouteParsed", reason: "effect").unexposed("gpxImportFailed", reason: "effect")
      .unexposed("openURL", reason: "effect").unexposed("alert", reason: "effect")  // the GPX import error
      .unexposed("view.observationModeChanged", reason: "effect")  // onAppear's publisher of the shared setting
      .child("rideEvents", state: { if case let .rideEventSettings(s)? = settingsDestination($0) { s } else { nil } },
        action: { .destination(.presented(.rideEventSettings($0))) }, descriptor: rideEventSettings)
      .child("appearance", state: { if case let .appearanceSettings(s)? = settingsDestination($0) { s } else { nil } },
        action: { .destination(.presented(.appearanceSettings($0))) }, descriptor: appearance)
      .child("privacyZones", state: { if case let .privacyZonesSettings(s)? = settingsDestination($0) { s } else { nil } },
        action: { .destination(.presented(.privacyZonesSettings($0))) }, descriptor: privacyZones)
  }

  static var rideEventSettings: FeatureDescriptor<RideEventsSettingsFeature.State, RideEventsSettingsFeature.Action> {
    let type = FeatureDescriptor<RideEventType.State, RideEventType.Action>("Ride type", observation: {
      .object(["type": .string($0.rideType.rawValue), "shown": .bool($0.isEnabled)])
    })
      .operation("show", label: "Show rides of this type", action: .binding(.set(\.isEnabled, true)), available: { !$0.isEnabled })
      .operation("hide", label: "Hide rides of this type", action: .binding(.set(\.isEnabled, false)), available: { $0.isEnabled })
    return FeatureDescriptor<RideEventsSettingsFeature.State, RideEventsSettingsFeature.Action>("Event settings", observation: { state in
      .object([
        "eventsOn": .bool(state.isEnabled),
        "radiusKm": .number(Double(state.eventSearchRadius.rawValue)),
        "types": .array(state.rideEventTypes.map { .object(["id": .string($0.id), "shown": .bool($0.isEnabled)]) }),
      ])
    })
      .operation("on", label: "Turn ride events on", action: .binding(.set(\.isEnabled, true)), available: { !$0.isEnabled })
      .operation("off", label: "Turn ride events off", action: .binding(.set(\.isEnabled, false)), available: { $0.isEnabled })
      .operation("radius", label: "Set the ride search radius (km)", arguments: Choice<EventDistanceKm>.self,
        action: { .binding(.set(\.eventSearchRadius, EventDistance(rawValue: Int($0.value.rawValue)!)!)) },
        available: { $0.isEnabled })
      .identified("types", state: \.rideEventTypes, action: \.rideEventType, descriptor: type).covering("rideEventType")
      .invariant("the screen matches the saved event settings") { state in
        @Shared(.rideEventSettings) var saved
        return saved.isEnabled == state.isEnabled && saved.eventDistance == state.eventSearchRadius
          && Set(saved.rideEvents.filter(\.isEnabled).map(\.rideType)) == Set(state.rideEventTypes.filter(\.isEnabled).map(\.rideType))
      }
  }

  static var appearance: FeatureDescriptor<AppearanceSettingsFeature.State, AppearanceSettingsFeature.Action> {
    FeatureDescriptor<AppearanceSettingsFeature.State, AppearanceSettingsFeature.Action>("Appearance", observation: {
      .object(["theme": .string($0.colorScheme.rawValue), "appIcon": .string($0.appIcon.rawValue)])
    })
      .operation("theme", label: "Set the theme", arguments: Choice<AppearanceSettings.ColorScheme>.self,
        action: { .binding(.set(\.colorScheme, $0.value)) })
      .operation("icon", label: "Set the app icon", arguments: Choice<AppIcon>.self, action: { .binding(.set(\.appIcon, $0.value)) })
      .invariant("the screen matches the saved appearance") { state in
        @Shared(.appearanceSettings) var saved
        return saved.colorScheme == state.colorScheme && saved.appIcon == state.appIcon
      }
  }

  static var privacyZones: FeatureDescriptor<PrivacyZoneFeature.State, PrivacyZoneFeature.Action> {
    typealias P = PrivacyZoneFeature.State
    let zonesOn: (P) -> Bool = { _ in @Shared(.privacyZoneSettings) var zones; return zones.isEnabled }
    let idle: (P) -> Bool = { zonesDestination($0) == nil && zoneAlert($0) == nil }
    // `ZoneRow`: the switch writes `isActive` through an internal subscript binding, which does what
    // `toggleZoneActive` does; the swipe action sends `deleteZone`.
    let row = FeatureDescriptor<PrivacyZone, PrivacyZoneFeature.Action>("Privacy zone", observation: observeZone, identity: { $0.id })
      .operation("off", label: "Turn this zone off", available: { $0.isActive }) { .toggleZoneActive($0) }
      .operation("on", label: "Turn this zone on", available: { !$0.isActive }) { .toggleZoneActive($0) }
      .operation("delete", label: "Delete this zone") { .deleteZone($0) }
    let descriptor = FeatureDescriptor<P, PrivacyZoneFeature.Action>("Privacy zones", observation: observePrivacyZones)
      // The empty screen's button sends `togglePrivacyZones`; the form's switch writes the same
      // shared setting directly.
      .operation("on", label: "Turn privacy zones on", action: .togglePrivacyZones, available: { idle($0) && !zonesOn($0) })
      .operation("off", label: "Turn privacy zones off", action: .togglePrivacyZones, available: { idle($0) && zonesOn($0) })
      .operation("toggleMap", label: "Show or hide zones on the map", action: .toggleShowZonesOnMap,
        available: { idle($0) && zonesOn($0) })
      // The + button, disabled while the feature is off.
      .operation("add", label: "Add a privacy zone", action: .addZoneButtonTapped, available: { idle($0) && zonesOn($0) })
      .operation("swipeDownCreate", label: "Swipe down to close the new zone", action: .destination(.dismiss),
        available: { zonesDestination($0) != nil })
      .operation("confirmDelete", label: "Delete the zone", action: .alert(.presented(.deleteZoneButtonTapped)),
        available: { zoneAlert($0) != nil })
      .operation("cancelDelete", label: "Keep the zone", action: .alert(.dismiss), available: { zoneAlert($0) != nil })
      .child("create", state: { if case let .createZoneSheet(s)? = zonesDestination($0) { s } else { nil } },
        action: { .destination(.presented(.createZoneSheet($0))) }, descriptor: createZone)
      .covering("deleteZone", "toggleZoneActive")  // Sent by the rows
      .unexposed("selectZone", reason: "no view sends it")
      .unexposed("binding", reason: "binding")  // ZoneRow's switch, exposed as toggleZoneActive
    // "Your zones": the zones live in `@Shared(.privacyZoneSettings)`; one child per position, like the rides.
    var list = FeatureDescriptor<P, PrivacyZoneFeature.Action>("Your zones", observation: { _ in .object([:]) })
    for index in 0..<10 {
      list = list.child("\(index)", state: { _ in
        @Shared(.privacyZoneSettings) var zones
        return zones.zones.indices.contains(index) ? zones.zones[index] : nil
      }, action: { $0 }, descriptor: row)
    }
    return descriptor.child("zones", state: { state in
      @Shared(.privacyZoneSettings) var zones
      return zones.zones.isEmpty ? nil : state
    }, action: { $0 }, descriptor: list)
  }

  /// `CreatePrivacyZoneView`. Tapping the map sends `setMapCenter` with the tapped coordinate; the
  /// harness offers the one coordinate it knows, your (fixed) position.
  static var createZone: FeatureDescriptor<CreateZoneFeature.State, CreateZoneFeature.Action> {
    FeatureDescriptor<CreateZoneFeature.State, CreateZoneFeature.Action>("New privacy zone", observation: { state in
      .object([
        "name": .string(state.newZoneName), "radius": .number(state.newZoneRadius),
        "placed": .bool(state.mapCenter != nil), "canCreate": .bool(state.canCreateZone),
      ])
    })
      .operation("placeHere", label: "Place the zone at your position",
        action: .setMapCenter(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)))
      .operation("name", label: "Name the zone", arguments: String.self, action: { .binding(.set(\.newZoneName, $0)) })
      // The slider: 100 to 1000 m in steps of 50, disabled until the zone is placed.
      .operation("radius", label: "Set the zone radius (m)", arguments: Int.self,
        action: { .binding(.set(\.newZoneRadius, Double($0))) }, available: { $0.mapCenter != nil },
        validate: { _, value in
          guard (100...1000).contains(value), value % 50 == 0 else { throw HarnessArgumentError("100 to 1000 m in steps of 50") }
        })
      // The sheet closes from an effect (`delegate(.zoneCreated)`, then `dismiss()`): running until it's gone.
      .operation("create", label: "Create the zone", action: .createZone, available: \.canCreateZone,
        completion: { _ in .running })
      .operation("cancel", label: "Cancel the new zone", action: .dismiss)
      .unexposed("delegate", reason: "effect")
  }

  static var rides: FeatureDescriptor<RideEvents.State, RideEvents.Action> {
    let row = FeatureDescriptor<Ride, RideEvents.Action>("Ride", observation: observeRide, identity: { $0.id })
      .operation("select", label: "Show this ride on the map") { .selectRide($0) }
    var descriptor = FeatureDescriptor<RideEvents.State, RideEvents.Action>("Upcoming rides", observation: { _ in .object([:]) })
      // AppView: `.accessibilityAction(.escape) { store.send(.dismiss) }`. Swiping down is on the root.
      .operation("escape", label: "Close with the VoiceOver escape gesture", action: .dismiss)
      .covering("selectRide")  // Sent by the rows ("Show this ride on the map")
    // `rideEvents` is internal to AppFeature and not an IdentifiedArray: one child per position.
    for index in 0..<10 {
      descriptor = descriptor.child("\(index)", state: { state in
        let rides: [Ride] = field(state, "rideEvents") ?? []
        return rides.indices.contains(index) ? rides[index] : nil
      }, action: { $0 }, descriptor: row)
    }
    return descriptor
  }
}

// MARK: - Observation

extension CriticalMapsHarness {
  nonisolated static func destination(_ state: AppFeature.State) -> Destination? { presented(state, "destination") }
  nonisolated static func settingsDestination(_ state: SettingsFeature.State) -> SettingsFeature.Destination.State? { presented(state, "destination") }

  /// `@Presents var destination` is internal to the upstream modules; read it the way a debugger would.
  nonisolated static func presented<Value>(_ state: Any, _ field: String) -> Value? {
    for child in Mirror(reflecting: state).children where child.label == "_" + field || child.label == field {
      if let wrapper = child.value as? PresentationState<Value> { return wrapper.wrappedValue }
      if let value = child.value as? Value? { return value }
    }
    return nil
  }

  nonisolated static func field<Value>(_ state: Any, _ name: String) -> Value? {
    Mirror(reflecting: state).children.first { $0.label == name || $0.label == "_" + name }?.value as? Value
  }

  static func nextRideBanner(_ state: AppFeature.State) -> Bool {
    @Shared(.rideEventSettings) var rideEvents
    return state.mapFeatureState.isNextRideBannerVisible && rideEvents.isEnabled
  }

  static func observe(_ state: AppFeature.State) -> HarnessValue {
    let map = state.mapFeatureState
    let sheet: String? = switch destination(state) {
    case .whatsNew?: "whatsNew"
    case .social?: "social"
    case .settings?: "settings"
    case .rideEvents?: "rides"
    case nil: nil
    }
    @Shared(.hasConnectionError) var connectionError
    @Shared(.privacyZoneSettings) var zones
    @Shared(.lastSeenWhatsNewVersion) var whatsNewSeen
    var root: [String: HarnessValue] = [
      "sheet": sheet.map(HarnessValue.string) ?? .null,
      "map": .object([
        "riders": .number(Double(map.riderLocations.count)),  // what the map draws
        "riderCountShown": .string(state.ridersCount),
        "you": map.location.map { .object(["latitude": .number($0.coordinate.latitude), "longitude": .number($0.coordinate.longitude)]) } ?? .null,
        "gps": HarnessLocation.shared.observation,
        "observationMode": .bool(state.settingsState.userSettings.isObservationModeEnabled),
        "infoOverlay": .bool(state.settingsState.userSettings.showInfoViewEnabled),
        "tracking": .string(["none", "follow", "followWithHeading"][min(Int(map.userTrackingMode.mode.rawValue), 2)]),
        "nextRide": map.nextRide.map(observeRide) ?? .null,
        "nextRideBanner": .bool(nextRideBanner(state)),
        "loadingRiders": .bool(state.isRequestingRiderLocations),
        "connectionError": .bool(connectionError),
        // What the info overlay shows ("in a privacy zone"), next to what the zones say about you.
        "inPrivacyZone": .bool(state.isCurrentLocationInPrivacyZone),
        "insideActiveZone": .bool(map.location.map { zones.isLocationInPrivacyZone(
          Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) } ?? false),
        "locationsPosted": .number(Double(HarnessPosting.shared.posted)),
        "shareSheet": .bool(map.presentShareSheet),
      ]),
      "chatBadge": .number(Double(state.chatMessageBadgeCount)),
      // `lastSeenWhatsNewVersion`: set by `whatsNewDismissed`, which the sheet's `onDismiss` sends.
      "whatsNewSeen": whatsNewSeen.isEmpty ? .null : .string(whatsNewSeen),
      "openedURLs": .array(HarnessApplication.opened.value.map(HarnessValue.string)),
    ]
    switch destination(state) {
    case .social(let social)?: root["social"] = observeSocial(social)
    case .settings(let settings)?: root["settings"] = observeSettings(settings)
    case .rideEvents?: root["rides"] = .array(state.nextRideState.rideEvents.map(observeRide))
    case .whatsNew?: root["whatsNew"] = .object([:])
    case nil: break
    }
    return .object(root)
  }

  static func observeRide(_ ride: Ride) -> HarnessValue {
    .object([
      "id": .number(Double(ride.id)), "title": .string(ride.title),
      "date": .string(ride.dateTime.formatted(.iso8601)), "location": ride.location.map(HarnessValue.string) ?? .null,
      "type": ride.rideType.map { .string($0.rawValue) } ?? .null,
    ])
  }

  static func observeSocial(_ state: SocialFeature.State) -> HarnessValue {
    var value: [String: HarnessValue] = ["tab": .string(state.socialControl == .chat ? "chat" : "mastodon")]
    if state.socialControl == .chat { value["chat"] = observeChat(state.chatFeatureState) }
    else { value["mastodon"] = observeMastodon(state.mastodonFeedState) }
    return .object(value)
  }

  static func observeChat(_ state: ChatFeature.State) -> HarnessValue {
    let status: String = switch state.chatMessages {
    case .loading: "loading"
    case .results: "loaded"
    case .error: "error"
    default: "unknown"
    }
    return .object([
      "status": .string(status),
      "messages": .array(state.messages.map { .object(["id": .string($0.id), "text": .string($0.decodedMessage),
        "time": .string(Date(timeIntervalSince1970: $0.timestamp).formatted(.iso8601))]) }),
      "draft": .string(state.chatInputState.message),
      "sending": .bool(state.chatInputState.isSending),
      "alert": .bool(state.alert != nil),
    ])
  }

  /// What `TootsListView` shows, in its order of precedence.
  static func feedScreen(_ state: TootFeedFeature.State) -> String {
    if state.isLoading, !state.isRefreshing { return "loading" }
    if state.toots.isEmpty { return "empty" }
    if state.error != nil { return "error" }
    return "list"
  }

  static func observeMastodon(_ state: TootFeedFeature.State) -> HarnessValue {
    .object([
      "screen": .string(feedScreen(state)),
      "toots": .array(state.toots.map(observeToot)),
      "refreshing": .bool(state.isRefreshing),
      "loadingMore": .bool(state.isLoadingNextPage),
      "hasMore": .bool(state.hasMore),
    ])
  }

  static func observeToot(_ state: TootFeature.State) -> HarnessValue {
    .object(["id": .string(state.id), "author": .string(state.accountDisplayName), "account": .string(state.accountAcct),
      "posted": .string(state.createdAt.formatted(.iso8601)), "images": .number(Double(state.mediaAttachments.count))])
  }

  static func observeSettings(_ state: SettingsFeature.State) -> HarnessValue {
    let page: String? = switch settingsDestination(state) {
    case .rideEventSettings?: "rideEvents"
    case .appearanceSettings?: "appearance"
    case .privacyZonesSettings?: "privacyZones"
    case .guideFeature?: "guide"
    case .acknowledgements?: "acknowledgements"
    case nil: nil
    }
    var value: [String: HarnessValue] = [
      "page": page.map(HarnessValue.string) ?? .null,
      "observationMode": .bool(state.userSettings.isObservationModeEnabled),
      "infoOverlay": .bool(state.userSettings.showInfoViewEnabled),
      "highlightRiders": .bool(state.userSettings.highlightActiveRiders),
      "gpxRoute": state.userSettings.gpxRoute.map { .string($0.name ?? "route") } ?? .null,
      "eventsOn": .bool(state.rideEventSettings.isEnabled),
      "theme": .string(state.appearanceSettings.colorScheme.rawValue),
    ]
    switch settingsDestination(state) {
    case .rideEventSettings(let s)?: value["rideEvents"] = rideEventSettings.snapshot(s)
    case .appearanceSettings(let s)?: value["appearance"] = appearance.snapshot(s)
    case .privacyZonesSettings(let s)?: value["privacyZones"] = privacyZones.snapshot(s)
    default: break
    }
    return .object(value)
  }
}

extension CriticalMapsHarness {
  nonisolated static func zonesDestination(_ state: PrivacyZoneFeature.State) -> PrivacyZoneFeature.Destination.State? {
    presented(state, "destination")
  }
  nonisolated static func zoneAlert(_ state: PrivacyZoneFeature.State) -> AlertState<PrivacyZoneFeature.Action.Alert>? {
    presented(state, "alert")
  }

  static func observeZone(_ zone: PrivacyZone) -> HarnessValue {
    .object(["name": .string(zone.name), "active": .bool(zone.isActive), "radius": .number(zone.radius),
      "latitude": .number(zone.center.latitude), "longitude": .number(zone.center.longitude)])
  }

  static func observePrivacyZones(_ state: PrivacyZoneFeature.State) -> HarnessValue {
    @Shared(.privacyZoneSettings) var zones
    var value: [String: HarnessValue] = [
      "zonesOn": .bool(zones.isEnabled), "showOnMap": .bool(zones.shouldShowZonesOnMap),
      "zones": .array(zones.zones.map(observeZone)),
      "confirmingDelete": .bool(zoneAlert(state) != nil),
    ]
    if case let .createZoneSheet(create)? = zonesDestination(state) { value["creating"] = createZone.snapshot(create) }
    return .object(value)
  }
}

// MARK: - Arguments

/// A string argument limited to an enum's raw values.
struct Choice<Value: RawRepresentable & CaseIterable & Sendable>: HarnessInput where Value.RawValue == String {
  let value: Value
  static var harnessSchema: HarnessJSONSchema { .string(choices: Value.allCases.map(\.rawValue)) }
  init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let value = Value(rawValue: text) else { throw HarnessArgumentError("unknown value \(text)") }
    self.value = value
  }
  func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value.rawValue) }
}

enum EventDistanceKm: String, CaseIterable, Sendable { case five = "5", ten = "10", twenty = "20" }
extension AppIcon: @retroactive @unchecked Sendable {}

// MARK: - Fakes for outside effects

/// Location for harness runs: a fixed coordinate, never the device's.
///
/// `CRITICALMAPS_HARNESS_LOCATION` picks the permission story: `allow` (default: the app asks and the
/// user allows), `deny` (the user declines), `granted` (allowed before launch), `denied` (declined
/// before launch).
final class HarnessLocation: @unchecked Sendable {
  static let shared = HarnessLocation()
  private let lock = NSLock()
  private var status: CLAuthorizationStatus = .notDetermined
  private var answer: CLAuthorizationStatus = .authorizedAlways
  private var updating = false
  private var listeners: [UUID: AsyncStream<LocationManager.Action>.Continuation] = [:]
  private var pending: [LocationManager.Action] = []
  var location: ComposableCoreLocation.Location {
    Location(coordinate: CLLocationCoordinate2D(latitude: CriticalMapsHarness.coordinate.latitude,
      longitude: CriticalMapsHarness.coordinate.longitude), timestamp: HarnessDeterministic.startDate)
  }

  @MainActor var observation: HarnessValue {
    locked {
      let permission = switch status {
      case .authorizedAlways, .authorizedWhenInUse: "allowed"
      case .denied, .restricted: "denied"
      default: "not asked"
      }
      return .object(["permission": .string(permission), "updating": .bool(updating)])
    }
  }

  func manager(environment: [String: String]) -> LocationManager {
    switch environment["CRITICALMAPS_HARNESS_LOCATION"] ?? "allow" {
    case "deny": answer = .denied
    case "granted": status = .authorizedAlways
    case "denied": status = .denied
    default: break
    }
    var manager = LocationManager()
    manager.authorizationStatus = { self.locked { self.status } }
    manager.accuracyAuthorization = { .fullAccuracy }
    manager.locationServicesEnabled = { true }
    manager.location = { self.locked { self.isAllowed ? self.location : nil } }
    manager.set = { _ in }
    manager.requestAlwaysAuthorization = { self.decide() }
    manager.requestWhenInUseAuthorization = { self.decide() }
    manager.requestLocation = { if self.locked({ self.isAllowed }) { self.send(.didUpdateLocations([self.location])) } }
    manager.startUpdatingLocation = {
      guard self.locked({ self.isAllowed }) else { return }
      self.locked { self.updating = true }
      self.send(.didUpdateLocations([self.location]))
    }
    manager.stopUpdatingLocation = { self.locked { self.updating = false } }
    manager.delegate = {
      let (stream, continuation) = AsyncStream<LocationManager.Action>.makeStream()
      let id = UUID()
      let queued = self.locked { () -> [LocationManager.Action] in
        self.listeners[id] = continuation
        defer { self.pending = [] }
        return self.pending
      }
      queued.forEach { continuation.yield($0) }
      continuation.onTermination = { _ in self.locked { _ = self.listeners.removeValue(forKey: id) } }
      return stream
    }
    return manager
  }

  private var isAllowed: Bool { status == .authorizedAlways || status == .authorizedWhenInUse }
  var isUpdating: Bool { locked { updating } }

  private func decide() {
    let decided = locked { () -> CLAuthorizationStatus? in
      guard status == .notDetermined else { return nil }
      status = answer
      return answer
    }
    if let decided { send(.didChangeAuthorization(decided)) }
  }

  private func send(_ action: LocationManager.Action) {
    let listeners = locked { () -> [AsyncStream<LocationManager.Action>.Continuation] in
      if self.listeners.isEmpty { pending.append(action) }
      return Array(self.listeners.values)
    }
    listeners.forEach { $0.yield(action) }
  }

  private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

/// Every location the app hands its API client to post, checked against the privacy zones at that
/// moment. The request itself still goes through `HarnessNetwork` (and the live guard refuses it).
final class HarnessPosting: @unchecked Sendable {
  static let shared = HarnessPosting()
  private let lock = NSLock()
  private var _posted = 0
  private var _fromInsideZone = 0
  var posted: Int { lock.withLock { _posted } }
  var fromInsideZone: Int { lock.withLock { _fromInsideZone } }

  static func watching(_ service: APIService) -> APIService {
    var watched = service
    watched.postRiderLocation = { body in
      @Shared(.privacyZoneSettings) var zones
      let inside = body.location.map { zones.isLocationInPrivacyZone($0.coordinate) } ?? false
      shared.lock.withLock {
        shared._posted += 1
        if inside { shared._fromInsideZone += 1 }
      }
      return try await service.postRiderLocation(body)
    }
    return watched
  }
}

/// Outside-the-app effects are recorded, not performed: no Safari, no icon-change alert.
enum HarnessApplication {
  static let opened = LockIsolated<[String]>([])

  static func client(headless: Bool) -> UIApplicationClient {
    var client = UIApplicationClient.previewValue
    client.open = { url, _ in opened.withValue { $0.append(url.absoluteString) }; return true }
    client.alternateIconNameAsync = { nil }
    if !headless { client.setUserInterfaceStyle = UIApplicationClient.liveValue.setUserInterfaceStyle }
    return client
  }
}
