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
          guard case let .social(social)? = destination(state) else { return .running }
          return chatLoaded(social)
        })
      .operation("openSettings", label: "Open settings", action: .settingsButtonTapped, available: noSheet)
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
      .child("social", state: { if case let .social(s)? = destination($0) { s } else { nil } },
        action: { .destination(.presented(.social($0))) }, descriptor: social)
      .child("settings", state: { if case let .settings(s)? = destination($0) { s } else { nil } },
        action: { .destination(.presented(.settings($0))) }, descriptor: settings)
      .operation("swipeDownRides", label: "Swipe the upcoming rides down", action: .destination(.dismiss),
        available: { if case .rideEvents? = destination($0) { true } else { false } })
      .child("rides", state: { if case let .rideEvents(s)? = destination($0) { s } else { nil } },
        action: { .destination(.presented(.rideEvents($0))) }, descriptor: rides)
      .invariant("the map shows the riders that were fetched") { $0.riderLocations == $0.mapFeatureState.riderLocations }
      .invariant("no rider appears twice") { Set($0.riderLocations.map(\.id)).count == $0.riderLocations.count }
      .invariant("unread badge never exceeds the messages") {
        Int($0.chatMessageBadgeCount) <= ($0.socialState.chatFeatureState.chatMessages.elements?.count ?? 0)
      }
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
      .identified("toots", state: \.toots, action: \.toot, descriptor: toot)
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
      .identified("types", state: \.rideEventTypes, action: \.rideEventType, descriptor: type)
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
    FeatureDescriptor<PrivacyZoneFeature.State, PrivacyZoneFeature.Action>("Privacy zones", observation: { _ in
      @Shared(.privacyZoneSettings) var zones
      return .object([
        "zonesOn": .bool(zones.isEnabled), "showOnMap": .bool(zones.shouldShowZonesOnMap),
        "zones": .array(zones.zones.map { .object(["name": .string($0.name), "active": .bool($0.isActive), "radius": .number($0.radius)]) }),
      ])
    })
      .operation("toggle", label: "Turn privacy zones on or off", action: .togglePrivacyZones)
      .operation("toggleMap", label: "Show or hide zones on the map", action: .toggleShowZonesOnMap)
  }

  static var rides: FeatureDescriptor<RideEvents.State, RideEvents.Action> {
    let row = FeatureDescriptor<Ride, RideEvents.Action>("Ride", observation: observeRide, identity: { $0.id })
      .operation("select", label: "Show this ride on the map") { .selectRide($0) }
    var descriptor = FeatureDescriptor<RideEvents.State, RideEvents.Action>("Upcoming rides", observation: { _ in .object([:]) })
      // AppView: `.accessibilityAction(.escape) { store.send(.dismiss) }`. Swiping down is on the root.
      .operation("escape", label: "Close with the VoiceOver escape gesture", action: .dismiss)
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
    var root: [String: HarnessValue] = [
      "sheet": sheet.map(HarnessValue.string) ?? .null,
      "map": .object([
        "riders": .number(Double(state.riderLocations.count)),
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
        "inPrivacyZone": .bool(state.isCurrentLocationInPrivacyZone),
        "shareSheet": .bool(map.presentShareSheet),
      ]),
      "chatBadge": .number(Double(state.chatMessageBadgeCount)),
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
