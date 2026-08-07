import SwiftUI
import Observation

/// Global device/cloud playback mode (Item 7 — fully wired by Native2/Server). Defined
/// here as the natural home; the `SetlistPlayer.playbackMode` seam already consumes it.
///   • `.cloud`  — stream (Apple Music → rip-on-demand fallback), today's behaviour.
///   • `.device` — play from burned local files (fall back to cloud for a missing file).
enum PlaybackMode: String, Codable, Hashable, Sendable { case cloud, device }

/// Whole-session repeat mode for the `SetlistPlayer` run — surfaced on the Now Playing deck,
/// the widget, and the system lock-screen / CarPlay card. DISTINCT from `SetlistPlayer.Item.repeatCount`
/// (a per-track performance loop count): this governs what happens at the END of the whole queue.
///   • `.off` — stop at the end of the queue (today's behaviour).
///   • `.all` — wrap to the top and keep going (repeat the whole session).
///   • `.one` — replay the CURRENT track on its natural end (an explicit ⏭ still advances).
/// Raw values are persisted in the durable playback session — never rename them.
enum RepeatMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case off, all, one
    var id: String { rawValue }
    /// off → all → one → off — the Now Playing / widget repeat button's cycle.
    var next: RepeatMode { self == .off ? .all : (self == .all ? .one : .off) }
}

/// Which output channel the Mix CUE / monitor bus is sent to (the other side carries the house mix).
/// Used by the two-deck Mix board's pre-fade-listen: e.g. `.right` ⇒ cue on the right channel, house
/// on the left — the standard "send main out one channel, cue out the other" booth wiring.
enum CueChannel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case right, left
    var id: String { rawValue }
    var label: String { self == .right ? "Right (main on left)" : "Left (main on right)" }
    /// True when the cue bus pans to the RIGHT — the form the engine consumes.
    var onRight: Bool { self == .right }
}

/// How the two Mix decks are arranged (an iOS-only "view mode" — macOS always uses side-by-side,
/// there's room). iPhone portrait crams two decks into a narrow width, so this lets you trade the
/// two-up board for taller, finger-friendly controls:
///   • `.sideBySide` — the classic two decks side by side (A left, B right).
///   • `.stacked`    — full-width decks, one above the other. The DEFAULT (best in portrait).
///   • `.single`     — one deck at a time, flanked by ‹ › buttons that flip to the other deck.
/// Consumed by `MixView.deckArea`; the picker lives in Settings ▸ Mix (iOS only).
enum MixDeckLayout: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case sideBySide, stacked, single
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .stacked:    return "Stacked"
        case .single:     return "Single deck"
        }
    }
    var systemImage: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .stacked:    return "rectangle.split.1x2"
        case .single:     return "rectangle.portrait"
        }
    }
}

/// How the Playlists screen orders the user's collections (and each Shared-tab source group).
/// Persisted in `SettingsStore.collectionSort` as the raw string; `.name` (A–Z) is the default
/// on a fresh install AND on upgrade (a missing key coalesces to it). Mirrors `MixDeckLayout`.
enum CollectionSortOrder: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case recentlyPlayed, name, lastUpdated
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recentlyPlayed: return "Recently played"
        case .name:           return "A–Z"
        case .lastUpdated:    return "Last updated"
        }
    }
    var systemImage: String {
        switch self {
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .name:           return "textformat"
        case .lastUpdated:    return "pencil.and.list.clipboard"
        }
    }

    /// Order a list of collections by this sort. `.name` = localizedCaseInsensitiveCompare;
    /// `.lastUpdated` = newest `updatedAt` first (tie-break name); `.recentlyPlayed` = newest
    /// `lastPlayedAt` first — never-played (nil ⇒ 0) sort LAST — then `updatedAt`, then name.
    func sorted<T: CollectionSortable>(_ items: [T]) -> [T] {
        switch self {
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUpdated:
            return items.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .recentlyPlayed:
            return items.sorted { lhs, rhs in
                let l = lhs.lastPlayedAt ?? 0, r = rhs.lastPlayedAt ?? 0
                if l != r { return l > r }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

/// A configurable catalog source (name + index URL + whether it's shown).
struct SourceConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var urlString: String
    var enabled: Bool = true

    var url: URL? { URL(string: urlString.trimmingCharacters(in: .whitespaces)) }
}

/// Persisted app settings (UserDefaults). Mirrors the PWA's Settings: data
/// sources, online-search credentials, and the rip-server config. Refresh /
/// data migrations are intentionally omitted — the App Store handles app updates
/// and any data migration ships inside a new version.
@MainActor
@Observable
final class SettingsStore {
    var sources: [SourceConfig]
    var ripServerURL: String
    var ripToken: String
    /// Jukebox Hero session broker base URL (Tailscale Funnel path mount — PUBLIC, unlike
    /// the rip server, since guests post requests from their own phones). See JukeboxClient.
    var jukeboxServerURL: String
    /// Optional server-level bearer for creating jukeboxes (JUKEBOX_TOKEN on the server).
    var jukeboxToken: String
    /// Default for whether a NEW jukebox session requires a per-session guest access token
    /// (each session's create-view toggle seeds from this and can override it). ON by default
    /// so a session is admits-only by default rather than open to anyone with the link.
    /// #TOUPDATE: the server (jukebox-server.mjs) must mint the guest token, bake it into the
    /// guest URL, and refuse tokenless guest requests — until then this flag rides the create
    /// call as intent but does not yet gate anyone.
    var jukeboxTokensRequiredByDefault: Bool
    /// When on, every rip the app requests asks the server to try capturing the song from
    /// the Apple Music library on the iMac (cloud), falling back to the analog (vinyl)
    /// source when there's no Apple Music match or the capture fails. No-op for songs that
    /// already rip from Apple Music (digital sources).
    var ripFromCloud: Bool
    /// Item 7 — global device/cloud playback mode. `.cloud` (default) streams via the
    /// coordinator (Apple Music → rip-on-demand); `.device` plays burned local files,
    /// falling back to cloud for a missing file. Read by `SetlistPlayer.playbackMode`
    /// + the single-row transport; toggled by the per-screen `PlaybackModeToggle`.
    var playbackMode: PlaybackMode
    var searchAccessKeyID: String
    var searchSecretKey: String
    var searchEndpoint: String
    /// Feature 2 (burnt-music FOLDER): a SECURITY-SCOPED bookmark to the user-picked folder
    /// burnt audio + sidecars are written into (so the files are browsable in Finder/Files).
    /// `nil` → BurnStore falls back to the app-managed Application Support `burns/` dir.
    var burnFolderBookmark: Data?
    /// Mix SESSION FOLDER: a SECURITY-SCOPED bookmark to the user-picked folder each mix session's
    /// data (recorded audio, and future per-session files) is written into — one subfolder per
    /// session. `nil` → app-managed Application Support `mix-sessions/` dir. Mirrors
    /// `burnFolderBookmark`; see `SessionFolders`.
    var sessionFolderBookmark: Data?
    /// Auto-Mix (Mix tab): seconds BEFORE a track ends to begin crossfading to the next deck.
    /// Default 15. Read when the user starts an auto-mix; clamped to a sane range in the UI.
    var autoMixLeadSeconds: Double
    /// Auto-Mix (Mix tab): duration in seconds of the crossfade (volume sweep) between decks.
    /// Default 3.
    var autoMixFadeSeconds: Double
    /// Auto-Mix (Mix tab): duration in seconds of the crossfade when the user TAPS the manual Skip
    /// button (a longer, deliberate transition than the automatic `autoMixFadeSeconds`). Default 15.
    /// A double-tap on Skip always uses a fast 5 s sweep regardless of this value.
    var skipFadeSeconds: Double
    /// Mix Glide length (Mix tab): seconds the tempo/pitch/effect eases in + back out per transition —
    /// longer = a smoother glide. Default 10. Pushed into `MixEngine.setMixGlideSeconds`.
    var mixGlideSeconds: Double
    /// Mix sessions: when on (default), the track loader HIDES songs already played in the current
    /// session; when off, they still show but with a ✓ checkmark. See `MixSessionStore`.
    var mixAutoHidePlayed: Bool
    /// Which output channel the Mix CUE / pre-fade-listen bus is sent to (default `.right`). Pushed
    /// into `MixEngine.setCueOnRight`. See `CueChannel`.
    var cueOutputChannel: CueChannel
    /// Mix decks flash a ring on each beat when ON; OFF (default) ⇒ no pulse. See `BeatPulseView`.
    var beatPulseEnabled: Bool
    /// iOS-only "view mode": how the two Mix decks are laid out — side-by-side, stacked (the
    /// default, best in portrait), or one-at-a-time with ‹ › switchers. macOS ignores it (always
    /// side-by-side). See `MixDeckLayout` + `MixView.deckArea`.
    var mixDeckLayout: MixDeckLayout
    /// How the Playlists screen orders the user's collections + each Shared-tab source group.
    /// Persisted (per-device — Settings isn't CloudSync-registered); default `.name` (A–Z).
    var collectionSort: CollectionSortOrder
    /// The last-visited section's rawValue ("" = the home menu) — iOS relaunches
    /// reopen there ("open to wherever you last left off"); macOS ignores it
    /// (always lands on Mix). Written by RootView on every section change.
    var lastSection: String?
    /// Storage manager SOFT CAP (decimal GB). UNSET (nil, the default) means the app never
    /// deletes media on its own — storage is managed manually with the delete tools. When
    /// set, a once-a-day prune evicts least-recently-played burned media until the burned
    /// footprint fits under the cap. See `StorageManager`.
    var storageSoftCapGB: Double?
    /// Epoch ms of the last completed daily prune (the once-a-day gate). nil = never.
    var lastStoragePruneAt: Double?
    /// Settings ▸ Debug: record the mix engine's diagnostic log (`MixDiag`) so a remote tester
    /// can export it and ship it back. OFF (default) ⇒ os_log only, nothing buffered.
    var debugLoggingEnabled: Bool
    /// Studio SAMPLES folder: a SECURITY-SCOPED bookmark to the user-picked folder rendered
    /// sample audio is written into (browsable in Finder/Files). `nil` → the app-managed
    /// Application Support `studio/samples/` dir. Mirrors `burnFolderBookmark`; see `StudioFolders`.
    var samplesFolderBookmark: Data?
    /// Studio LOOPS folder: same pattern for rendered loop files (`loop-<id>.caf`). `nil` →
    /// app-managed Application Support `studio/loops/`. See `StudioFolders`.
    var loopsFolderBookmark: Data?
    /// Studio SEQUENCES folder: same pattern for bounced sequencer patterns
    /// (`pattern-<id>.m4a`). `nil` → app-managed Application Support `studio/sequences/`.
    var sequencesFolderBookmark: Data?
    /// Studio INSTRUMENTALS (takes) folder: same pattern for recorded instrumentals
    /// (`take-<id>.m4a`). `nil` → app-managed Application Support `studio/takes/`. Instrument
    /// packs remain ALWAYS app-managed (no bookmark). See `StudioFolders`.
    var takesFolderBookmark: Data?
    /// The user's "PocketDJ name" — the ARTIST shown on their performance items (samples, loops,
    /// sequences, instrumentals) across collections + Now Playing, and written as the ID3 artist
    /// when those items are burned. Empty ⇒ the generic "Studio" label.
    var pocketDJName: String
    /// The last-visited Performance sub-tab's rawValue (Samples/Loops/Sequencer/Instruments/
    /// Cues) so the tab reopens where you left off — the Studio twin of `lastSection`.
    /// nil = never visited ⇒ the view's own default.
    var studioTab: String?
    /// Studio ▸ Instruments: metronome CLICK during take recording. ON by default; the click
    /// joins the graph downstream of the take-capture tap so it is never recorded.
    var studioClickEnabled: Bool
    /// Studio ▸ Instruments: 1-bar COUNT-IN before take recording starts (beat 1 = end of
    /// count-in = the score quantizer's anchor). ON by default.
    var studioCountInEnabled: Bool
    /// GLOBAL gate for converted-collection source sync (ON by default): when on, every
    /// catalog refresh reconciles each source-converted pocket AND source-duplicated
    /// playlist with its source playlist (adds/removals propagate; the user's own edits
    /// survive). Per-item opt-outs live on the items (`sourceSyncEnabled`, the detail ⋯
    /// menus); the manual "Sync from source now" actions ignore both gates. See
    /// `CollectionsStore.syncConvertedCollections`. (Field name predates playlist support —
    /// kept for the persisted-blob key.)
    var syncConvertedPockets: Bool
    /// iCloud sync of profile + session data (CloudSyncService) — ON by default; the
    /// service still degrades to a no-op without a signed-in iCloud account. The toggle
    /// lives in Settings ▸ Profile.
    var cloudSyncEnabled: Bool
    /// PRIVATE Apple Music syncing (Settings ▸ Apple Music ▸ Syncing): OFF (public, the default
    /// for everyone) = syncing talks to Apple Music directly with a token minted on this device;
    /// ON (private — Levi's iMac setup) = syncing runs through the user's own PocketDJ server +
    /// catalog, and the pane reveals the server-credential fields. ONE set of sync verbs either
    /// way — this only picks the backend. The default is CAPTURED ONCE at store construction
    /// (private iff an import server is configured) so later `ripServerURL` edits — shared
    /// plumbing that changes for reasons unrelated to Apple Music — can never silently flip a
    /// state the user has already seen.
    var appleMusicPrivateSyncRaw: Bool?
    var appleMusicPrivateSync: Bool {
        get { appleMusicPrivateSyncRaw ?? !ripServerURL.isEmpty }
        set { appleMusicPrivateSyncRaw = newValue }
    }
    /// EXPLICIT-VERSIONS preference (Settings ▸ Apple Music ▸ Syncing ▸ Explicit versions),
    /// stored TRI-STATE on purpose:
    ///   • nil (UNSET, the shipped default) — the user has never touched the toggle. NEW-song
    ///     discovery/recognizer picks and future catalog resolutions default to the CLEAN
    ///     edition, but streaming/playback of EXISTING catalog songs keeps playing each
    ///     song's primary cut untouched — so the variant re-index can never silently switch
    ///     the whole library's streams to clean out from under anyone's muscle memory.
    ///   • false (explicitly set) — prefer clean everywhere (streams substitute the clean
    ///     edition of an explicit-primary song when one is resolved).
    ///   • true — prefer explicit everywhere (Levi's restore: streams resolve
    ///     `appleMusicIdExplicit` first).
    /// The UI binds the Bool projection below; flipping the toggle EITHER way sets the raw.
    var preferExplicitVersionsRaw: Bool?
    var preferExplicitVersions: Bool {
        get { preferExplicitVersionsRaw ?? false }
        set { preferExplicitVersionsRaw = newValue }
    }
    /// TWO-WAY FAVORITES sync opt-in (Settings ▸ Apple Music ▸ Syncing ▸ Favorites): OFF by
    /// default — ♥ stays in the PocketDJ profile. ON pushes/pulls the user's OWN hearts with
    /// their OWN Music-User-Token (parity review: the old owner-allowlist gate made the verb a
    /// permanent no-op for everyone but the library owner, who stays always-on regardless).
    var favoritesTwoWaySync: Bool
    /// Adopt the library owner's shipped ♥ SEED onto this install (integrity audit): OFF by
    /// default so a public user's favorites are never silently seeded with someone else's picks.
    var applyOwnerFavoritesSeed: Bool
    /// DAILY AUTO-SYNC of Apple Music collections (Levi 2026-07-29): ON by default — the sync
    /// must not require sitting on the Settings screen. Fires once per day at
    /// `amAutoSyncMinutes` local time (launch/foreground/periodic catch-up; a missed slot runs
    /// at the next opportunity).
    var amAutoSyncEnabled: Bool
    /// Should a sync IMPORT Apple Music playlists that have no local counterpart?
    ///
    /// OFF by default, and deliberately so. The pull used to import EVERY Apple Music library
    /// playlist that wasn't already present locally, which meant an automatic 4:20 pass could copy
    /// the user's whole Apple Music library onto the device as PocketDJ playlists — including ones
    /// they never asked for. Levi 2026-08-02: "I only wanted to sync a playlist that I've added and
    /// that [is] sourced from an Apple Music playlist. I don't want it to automatically sync over
    /// every playlist in Apple Music."
    ///
    /// With this off, sync only touches collections the user EXPLICITLY linked — converted pockets
    /// and duplicated playlists. Turning it on restores the import-everything behaviour.
    var amImportNewPlaylists: Bool
    /// Minutes past local midnight for the daily auto-sync (default 4:20 PM = 980). Clamped.
    var amAutoSyncMinutes: Int {
        didSet {
            let c = min(max(amAutoSyncMinutes, 0), 1439)
            if c != amAutoSyncMinutes { amAutoSyncMinutes = c }
        }
    }
    /// Epoch ms of the last auto-sync CLAIM (stamped before the pass runs — the single-flight
    /// across triggers). nil = never.
    var lastAMAutoSyncAtMs: Double?
    /// How many days of collection ADD history the Apple Music write-back BACKFILL re-drives
    /// (Settings ▸ Apple Music ▸ Syncing, and History ▸ Collection). Default 2, clamped to 1…90
    /// so a corrupt or out-of-range value can never make the backfill scan nothing (or the whole
    /// log). The didSet ONLY clamps — persistence rides `AppleMusicSettingsView`'s
    /// `.onDisappear { persist() }` like every other control in that pane; a persisting didSet
    /// would re-write the blob during `resetEverything`'s reload right after it cleared it. See
    /// `CollectionsStore.backfillSourceWriteBacks`.
    var writeBackBackfillDays: Int {
        didSet {
            let c = min(max(writeBackBackfillDays, 1), CollectionsStore.writeBackBackfillMaxDays)
            if c != writeBackBackfillDays { writeBackBackfillDays = c }
        }
    }

    /// How many items the "Recently added" virtual playlist shows — the last N the profile added to
    /// its library (Apple Music library adds ranked by `dateAdded`, unioned with in-app ＋Add /
    /// imports / custom audio). Configurable in Settings ▸ Collections. Device-global like every
    /// SettingsStore value; the clamping didSet keeps a bad value from breaking the consumer. See
    /// `AppModel.recentlyAddedSongIds(limit:)`.
    var defaultRecentlyAddedCount: Int {
        didSet {
            let c = min(max(defaultRecentlyAddedCount, 1), Self.recentlyAddedMaxCount)
            if c != defaultRecentlyAddedCount { defaultRecentlyAddedCount = c }
        }
    }
    static let recentlyAddedDefaultCount = 3650
    static let recentlyAddedMaxCount = 100_000

    private let defaults: UserDefaults
    private static let key = "pdj.settings.v1"

    /// Whether a persisted settings blob existed when THIS store was constructed — the
    /// existing-user signal OnboardingStore's decision tree reads (an update must never
    /// show the first-run flow). Captured before anything can persist; App.init on a
    /// fresh install never persists settings (verified invariant — see OnboardingStore).
    @ObservationIgnored let hadPersistedSettings: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hadPersistedSettings = defaults.data(forKey: SettingsStore.key) != nil
        let data = SettingsStore.load(from: defaults)
        self.sources = data.sources
        self.ripServerURL = data.ripServerURL
        // UI-test seam: the shipping default rip-server URL is blank (features stay
        // dormant until the user configures a server), so tests that exercise a
        // configured-server state seed one via PDJ_RIP_SERVER_URL. No env var → no
        // change, so this is inert in every real build. (Mirrors PDJ_MIX_DECK_LAYOUT.)
        if let fixtureRip = ProcessInfo.processInfo.environment["PDJ_RIP_SERVER_URL"],
           !fixtureRip.isEmpty {
            self.ripServerURL = fixtureRip
        }
        self.ripToken = data.ripToken
        self.jukeboxServerURL = data.jukeboxServerURL ?? ""
        self.jukeboxToken = data.jukeboxToken ?? ""
        self.jukeboxTokensRequiredByDefault = data.jukeboxTokensRequiredByDefault ?? true
        self.ripFromCloud = data.ripFromCloud ?? false
        self.playbackMode = data.playbackMode.flatMap(PlaybackMode.init(rawValue:)) ?? .cloud
        self.searchAccessKeyID = data.searchAccessKeyID
        self.searchSecretKey = data.searchSecretKey
        self.searchEndpoint = data.searchEndpoint
        self.burnFolderBookmark = data.burnFolderBookmark
        self.sessionFolderBookmark = data.sessionFolderBookmark
        self.autoMixLeadSeconds = data.autoMixLeadSeconds ?? 15
        self.autoMixFadeSeconds = data.autoMixFadeSeconds ?? 3
        self.skipFadeSeconds = data.skipFadeSeconds ?? 15
        self.mixGlideSeconds = data.mixGlideSeconds ?? 10
        self.mixAutoHidePlayed = data.mixAutoHidePlayed ?? true
        self.cueOutputChannel = data.cueOutputChannel.flatMap(CueChannel.init(rawValue:)) ?? .right
        self.beatPulseEnabled = data.beatPulseEnabled ?? false
        self.mixDeckLayout = data.mixDeckLayout.flatMap(MixDeckLayout.init(rawValue:)) ?? .stacked
        self.collectionSort = data.collectionSort.flatMap(CollectionSortOrder.init(rawValue:)) ?? .name
        self.lastSection = data.lastSection
        self.storageSoftCapGB = data.storageSoftCapGB
        self.lastStoragePruneAt = data.lastStoragePruneAt
        self.debugLoggingEnabled = data.debugLoggingEnabled ?? false
        self.samplesFolderBookmark = data.samplesFolderBookmark
        self.loopsFolderBookmark = data.loopsFolderBookmark
        self.sequencesFolderBookmark = data.sequencesFolderBookmark
        self.takesFolderBookmark = data.takesFolderBookmark
        self.pocketDJName = data.pocketDJName ?? ""
        self.studioTab = data.studioTab
        self.studioClickEnabled = data.studioClickEnabled ?? true
        self.studioCountInEnabled = data.studioCountInEnabled ?? true
        self.syncConvertedPockets = data.syncConvertedPockets ?? true
        self.cloudSyncEnabled = data.cloudSyncEnabled ?? true
        // Legacy migration: pre-rename check builds persisted "local"/"remote" — map to the Bool.
        self.appleMusicPrivateSyncRaw = data.appleMusicPrivateSync
            ?? data.appleMusicSyncMode.map { $0 == "local" }
        // Tri-state on purpose: a missing key stays nil (UNSET) — never coalesced here.
        self.preferExplicitVersionsRaw = data.preferExplicitVersions
        self.favoritesTwoWaySync = data.favoritesTwoWaySync ?? false
        self.applyOwnerFavoritesSeed = data.applyOwnerFavoritesSeed ?? false
        self.amAutoSyncEnabled = data.amAutoSyncEnabled ?? true
        self.amImportNewPlaylists = data.amImportNewPlaylists ?? false
        self.amAutoSyncMinutes = min(max(data.amAutoSyncMinutes ?? AppleMusicAutoSync.defaultMinutes, 0), 1439)
        self.lastAMAutoSyncAtMs = data.lastAMAutoSyncAtMs
        self.writeBackBackfillDays = min(max(data.writeBackBackfillDays ?? CollectionsStore.writeBackBackfillDefaultDays,
                                             1), CollectionsStore.writeBackBackfillMaxDays)
        self.defaultRecentlyAddedCount = min(max(data.defaultRecentlyAddedCount ?? Self.recentlyAddedDefaultCount,
                                                 1), Self.recentlyAddedMaxCount)

        // UI-test seam: pin the Mix deck layout deterministically, independent of the persisted
        // value, so a test can exercise a specific arrangement (or hold the classic side-by-side
        // board while asserting on both decks). No-op in the shipping app (env unset).
        if let forced = ProcessInfo.processInfo.environment["PDJ_MIX_DECK_LAYOUT"],
           let layout = MixDeckLayout(rawValue: forced) {
            self.mixDeckLayout = layout
        }

        // CAPTURE the private-sync default now (after the PDJ_RIP_SERVER_URL seam so a seeded
        // server derives private): an unset value must become a fixed install-time choice, not a
        // live derivation that flips when ripServerURL is edited later. In-memory only — init
        // must never persist (the OnboardingStore fresh-install invariant); the value rides the
        // next natural persist().
        if appleMusicPrivateSyncRaw == nil {
            appleMusicPrivateSyncRaw = !ripServerURL.isEmpty
        }
    }

    /// Under UI tests (PDJ_USE_FIXTURE) use an isolated, freshly-cleared store so
    /// runs are deterministic and never touch the user's real settings.
    static func launchDefaults() -> UserDefaults {
        let env = ProcessInfo.processInfo.environment
        if env["PDJ_USE_FIXTURE"] != nil || env["PDJ_INTEGRATION_PLAYBACK"] == "1" {
            let name = "pdj.uitest.ephemeral"
            let d = UserDefaults(suiteName: name) ?? .standard
            d.removePersistentDomain(forName: name)
            return d
        }
        return .standard
    }

    var enabledSourceURLs: [URL] { sources.filter { $0.enabled }.compactMap { $0.url } }
    var searchConfigured: Bool { !searchAccessKeyID.isEmpty && !searchSecretKey.isEmpty }

    func addSource() {
        sources.append(SourceConfig(name: "New source", urlString: ""))
        persist()
    }

    var hasAppleMusic: Bool { sources.contains { $0.name == Config.appleMusicSourceName } }

    /// Opt-in: add the Apple Music (Local) source (same behavior as the PWA — not
    /// loaded by default; one tap adds it).
    func loadAppleMusic() {
        guard !hasAppleMusic else { return }
        sources.append(SourceConfig(name: Config.appleMusicSourceName,
                                    urlString: Config.appleMusicIndexURL.absoluteString,
                                    enabled: true))
        persist()
    }
    /// Match by name OR url so a renamed "My Digital" source still suppresses the one-tap
    /// loader (and can't be double-added with the same index URL).
    var hasMyDigital: Bool {
        let url = Config.digitalIndexURL.absoluteString
        let name = Config.digitalSourceName
        return sources.contains { $0.name == name || $0.urlString == url }
    }

    /// Opt-in: add the "My Digital" source (raw digital audio files indexed + uploaded to
    /// the rips bucket; pre-ripped, so they stream/burn with no rip step). One tap adds it.
    func loadMyDigital() {
        guard !hasMyDigital else { return }
        sources.append(SourceConfig(name: Config.digitalSourceName,
                                    urlString: Config.digitalIndexURL.absoluteString,
                                    enabled: true))
        persist()
    }
    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        persist()
    }

    /// Onboarding stage 3 ("Import your music"): reconcile the sources list to EXACTLY
    /// the chosen built-in set. The default blob pre-seeds "My Vinyl", so an unticked
    /// Vinyl must REMOVE it — one-tap loaders alone can't express that. Built-ins are
    /// matched by name OR index URL (the `hasMyDigital` doctrine); any custom source the
    /// user somehow already has is left untouched. At least one must be chosen — with
    /// Zero picks are legitimate since the zero-source boot fix: AppModel.fetchIndexes returns []
    /// with no enabled sources and the catalog builds from injection sources alone (the user's own
    /// Apple Music library, Discover adds, imports) — the own-library-only public configuration.
    func applyOnboardingSources(vinyl: Bool, digital: Bool, streaming: Bool) {
        // ZERO picks are legitimate since the zero-source catalog boot fix: the catalog builds
        // from injection sources alone (the user's own on-device Apple Music library, Discover
        // adds, imports) — an own-library-only install is exactly the public-user configuration.
        let builtins: [(want: Bool, name: String, url: String)] = [
            (vinyl, "My Vinyl", Config.indexURL.absoluteString),
            (digital, Config.digitalSourceName, Config.digitalIndexURL.absoluteString),
            (streaming, Config.appleMusicSourceName, Config.appleMusicIndexURL.absoluteString),
        ]
        for b in builtins {
            let present = sources.contains { $0.name == b.name || $0.urlString == b.url }
            if b.want && !present {
                sources.append(SourceConfig(name: b.name, urlString: b.url, enabled: true))
            } else if !b.want && present {
                sources.removeAll { $0.name == b.name || $0.urlString == b.url }
            }
        }
        persist()
    }

    /// Merge backup sources in: add any whose (name, urlString) pair isn't already
    /// present (a fresh UUID is minted so it can't collide). Returns the count added.
    @discardableResult
    func addSources(_ incoming: [SourceConfig]) -> Int {
        var added = 0
        for s in incoming {
            let dup = sources.contains { $0.name == s.name && $0.urlString == s.urlString }
            guard !dup else { continue }
            sources.append(SourceConfig(name: s.name, urlString: s.urlString, enabled: s.enabled))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func persist() {
        let snapshot = SettingsData(
            sources: sources, ripServerURL: ripServerURL, ripToken: ripToken,
            jukeboxServerURL: jukeboxServerURL, jukeboxToken: jukeboxToken,
            jukeboxTokensRequiredByDefault: jukeboxTokensRequiredByDefault,
            ripFromCloud: ripFromCloud, playbackMode: playbackMode.rawValue,
            searchAccessKeyID: searchAccessKeyID, searchSecretKey: searchSecretKey,
            searchEndpoint: searchEndpoint, burnFolderBookmark: burnFolderBookmark,
            sessionFolderBookmark: sessionFolderBookmark,
            autoMixLeadSeconds: autoMixLeadSeconds, autoMixFadeSeconds: autoMixFadeSeconds,
            skipFadeSeconds: skipFadeSeconds, mixGlideSeconds: mixGlideSeconds,
            mixAutoHidePlayed: mixAutoHidePlayed,
            cueOutputChannel: cueOutputChannel.rawValue,
            beatPulseEnabled: beatPulseEnabled,
            mixDeckLayout: mixDeckLayout.rawValue,
            collectionSort: collectionSort.rawValue,
            lastSection: lastSection,
            storageSoftCapGB: storageSoftCapGB,
            lastStoragePruneAt: lastStoragePruneAt,
            debugLoggingEnabled: debugLoggingEnabled,
            samplesFolderBookmark: samplesFolderBookmark,
            loopsFolderBookmark: loopsFolderBookmark,
            sequencesFolderBookmark: sequencesFolderBookmark,
            takesFolderBookmark: takesFolderBookmark,
            pocketDJName: pocketDJName,
            studioTab: studioTab,
            studioClickEnabled: studioClickEnabled,
            studioCountInEnabled: studioCountInEnabled,
            syncConvertedPockets: syncConvertedPockets,
            cloudSyncEnabled: cloudSyncEnabled,
            writeBackBackfillDays: writeBackBackfillDays,
            defaultRecentlyAddedCount: defaultRecentlyAddedCount,
            appleMusicSyncMode: nil,   // legacy field — decode-only since the private-toggle rename
            appleMusicPrivateSync: appleMusicPrivateSyncRaw,
            preferExplicitVersions: preferExplicitVersionsRaw,
            favoritesTwoWaySync: favoritesTwoWaySync,
            applyOwnerFavoritesSeed: applyOwnerFavoritesSeed,
            amAutoSyncEnabled: amAutoSyncEnabled,
            amImportNewPlaylists: amImportNewPlaylists,
            amAutoSyncMinutes: amAutoSyncMinutes,
            lastAMAutoSyncAtMs: lastAMAutoSyncAtMs)
        if let encoded = try? JSONEncoder().encode(snapshot) {
            defaults.set(encoded, forKey: SettingsStore.key)
        }
    }

    /// Wipe ALL on-device state: settings, the URL cache (covers + index), the per-source
    /// catalog disk cache, back to defaults.
    func resetEverything() {
        defaults.removeObject(forKey: SettingsStore.key)
        // Force the zero-to-hero flow on next launch. An explicit `pending` marker — NOT
        // blob-absence — because leaving the Settings tab after the reset re-persists the
        // blob via RootView's lastSection onChange, which would mask a blob-absence signal.
        OnboardingStore.markPendingAfterReset(in: defaults)
        URLCache.shared.removeAllCachedResponses()
        // Also drop CatalogService's persistent offline cache — otherwise a "reset" still
        // serves the last-good index for each source on the next failed fetch.
        if let dir = CatalogService.cacheDirectory() { try? FileManager.default.removeItem(at: dir) }
        let d = SettingsData.default
        sources = d.sources
        ripServerURL = d.ripServerURL; ripToken = d.ripToken
        jukeboxServerURL = d.jukeboxServerURL ?? ""
        jukeboxToken = d.jukeboxToken ?? ""
        jukeboxTokensRequiredByDefault = d.jukeboxTokensRequiredByDefault ?? true
        ripFromCloud = d.ripFromCloud ?? false
        playbackMode = d.playbackMode.flatMap(PlaybackMode.init(rawValue:)) ?? .cloud
        searchAccessKeyID = d.searchAccessKeyID; searchSecretKey = d.searchSecretKey
        searchEndpoint = d.searchEndpoint
        burnFolderBookmark = d.burnFolderBookmark
        sessionFolderBookmark = d.sessionFolderBookmark
        autoMixLeadSeconds = d.autoMixLeadSeconds ?? 15
        autoMixFadeSeconds = d.autoMixFadeSeconds ?? 3
        skipFadeSeconds = d.skipFadeSeconds ?? 15
        mixGlideSeconds = d.mixGlideSeconds ?? 10
        mixAutoHidePlayed = d.mixAutoHidePlayed ?? true
        cueOutputChannel = d.cueOutputChannel.flatMap(CueChannel.init(rawValue:)) ?? .right
        beatPulseEnabled = d.beatPulseEnabled ?? false
        mixDeckLayout = d.mixDeckLayout.flatMap(MixDeckLayout.init(rawValue:)) ?? .stacked
        collectionSort = d.collectionSort.flatMap(CollectionSortOrder.init(rawValue:)) ?? .name
        lastSection = d.lastSection
        storageSoftCapGB = d.storageSoftCapGB
        lastStoragePruneAt = d.lastStoragePruneAt
        debugLoggingEnabled = d.debugLoggingEnabled ?? false
        samplesFolderBookmark = d.samplesFolderBookmark
        loopsFolderBookmark = d.loopsFolderBookmark
        sequencesFolderBookmark = d.sequencesFolderBookmark
        takesFolderBookmark = d.takesFolderBookmark
        pocketDJName = d.pocketDJName ?? ""
        studioTab = d.studioTab
        studioClickEnabled = d.studioClickEnabled ?? true
        studioCountInEnabled = d.studioCountInEnabled ?? true
        syncConvertedPockets = d.syncConvertedPockets ?? true
        cloudSyncEnabled = d.cloudSyncEnabled ?? true
        // Mirror init's capture (reset clears ripServerURL, so the derived default is public) —
        // leaving this nil would revive the live-derivation behavior until the next launch.
        appleMusicPrivateSyncRaw = false
        // Back to UNSET (the fresh-install tri-state default), not false — a reset install
        // must behave exactly like a new one (no stream substitution until the user chooses).
        preferExplicitVersionsRaw = nil
        favoritesTwoWaySync = d.favoritesTwoWaySync ?? false
        applyOwnerFavoritesSeed = d.applyOwnerFavoritesSeed ?? false
        amAutoSyncEnabled = d.amAutoSyncEnabled ?? true
        amImportNewPlaylists = d.amImportNewPlaylists ?? false
        amAutoSyncMinutes = d.amAutoSyncMinutes ?? AppleMusicAutoSync.defaultMinutes
        lastAMAutoSyncAtMs = d.lastAMAutoSyncAtMs
        writeBackBackfillDays = min(max(d.writeBackBackfillDays ?? CollectionsStore.writeBackBackfillDefaultDays,
                                        1), CollectionsStore.writeBackBackfillMaxDays)
        defaultRecentlyAddedCount = min(max(d.defaultRecentlyAddedCount ?? Self.recentlyAddedDefaultCount,
                                            1), Self.recentlyAddedMaxCount)
    }

    private static func load(from defaults: UserDefaults) -> SettingsData {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: data)
        else { return .default }
        return decoded
    }
}

/// Codable snapshot persisted to UserDefaults.
struct SettingsData: Codable {
    var sources: [SourceConfig]
    var ripServerURL: String
    var ripToken: String
    /// Optional so older `pdj.settings.v1` blobs (which lack this key) still decode —
    /// Jukebox Hero server base (nil ⇒ blank, i.e. no server configured) + creation token.
    var jukeboxServerURL: String?
    var jukeboxToken: String?
    /// Optional so older blobs decode (a missing key ⇒ nil ⇒ the `?? true` default applies).
    var jukeboxTokensRequiredByDefault: Bool?
    /// Optional so older `pdj.settings.v1` blobs (which lack this key) still decode — a
    /// non-optional Bool would fail decode and silently reset ALL settings to defaults
    /// (load() falls back to .default via `try?`). Coalesced to false at the read sites.
    var ripFromCloud: Bool?
    /// Optional so older `pdj.settings.v1` blobs (which lack this key) still decode — same
    /// backward-compat rationale as `ripFromCloud`. Stored as the enum's raw string;
    /// coalesced to `.cloud` at the read sites.
    var playbackMode: String?
    var searchAccessKeyID: String
    var searchSecretKey: String
    var searchEndpoint: String
    /// Optional so older `pdj.settings.v1` blobs (which lack this key) still decode — same
    /// backward-compat rationale as `ripFromCloud` above.
    var burnFolderBookmark: Data?
    /// Optional so older blobs still decode — same backward-compat rationale as `burnFolderBookmark`.
    var sessionFolderBookmark: Data?
    /// Optional so older blobs still decode (coalesced to 15 / 3 at the read sites).
    var autoMixLeadSeconds: Double?
    var autoMixFadeSeconds: Double?
    /// Optional so older blobs still decode (coalesced to 15 at the read sites).
    var skipFadeSeconds: Double?
    /// Optional so older blobs still decode (coalesced to 10 at the read sites).
    var mixGlideSeconds: Double?
    /// Optional so older blobs still decode (coalesced to true at the read sites).
    var mixAutoHidePlayed: Bool?
    /// Optional so older blobs still decode (coalesced to `.right` at the read sites).
    var cueOutputChannel: String?
    /// Optional so older blobs still decode (coalesced to false at the read sites).
    var beatPulseEnabled: Bool?
    /// Optional so older blobs still decode — the iOS Mix deck-layout "view mode". Stored as the
    /// enum's raw string; coalesced to `.stacked` at the read sites.
    var mixDeckLayout: String?
    /// Optional so older blobs still decode — the Playlists collection sort. Stored as the
    /// enum's raw string; coalesced to `.name` (A–Z) at the read sites (default on upgrade).
    var collectionSort: String?
    /// Optional so older blobs still decode (nil = never persisted = home).
    var lastSection: String?
    /// Storage soft cap in decimal GB. Optional-by-design even when current: nil IS the
    /// meaningful default (no cap ⇒ no automatic storage management).
    var storageSoftCapGB: Double?
    /// Optional so older blobs still decode (nil = the daily prune has never run).
    var lastStoragePruneAt: Double?
    /// Optional so older blobs still decode — Settings ▸ Debug capture toggle (nil = off).
    var debugLoggingEnabled: Bool?
    /// Optional so older blobs still decode — Studio samples folder bookmark (nil = app-managed).
    var samplesFolderBookmark: Data?
    /// Optional so older blobs still decode — Studio loops folder bookmark (nil = app-managed).
    var loopsFolderBookmark: Data?
    /// Optional so older blobs still decode — Studio sequences folder bookmark (nil = app-managed).
    var sequencesFolderBookmark: Data?
    /// Optional so older blobs still decode — Studio instrumentals (takes) folder bookmark (nil = app-managed).
    var takesFolderBookmark: Data?
    /// Optional so older blobs still decode — the user's PocketDJ (performer) name (nil/"" = "Studio").
    var pocketDJName: String?
    /// Optional so older blobs still decode (nil = never visited ⇒ the view's default sub-tab).
    var studioTab: String?
    /// Optional so older blobs still decode (coalesced to true at the read sites).
    var studioClickEnabled: Bool?
    /// Optional so older blobs still decode (coalesced to true at the read sites).
    var studioCountInEnabled: Bool?
    /// Optional so older blobs still decode (coalesced to TRUE at the read sites — converted
    /// pockets sync with their source unless turned off).
    var syncConvertedPockets: Bool?
    /// Optional so older blobs still decode (coalesced to TRUE at the read sites — iCloud
    /// profile/session sync is on unless turned off in Settings ▸ Profile).
    var cloudSyncEnabled: Bool?
    /// Optional so older blobs still decode (coalesced + clamped to 1…90 at the read sites,
    /// default 2 — the Apple Music write-back backfill look-back window).
    var writeBackBackfillDays: Int?
    /// Optional so older blobs still decode (coalesced + clamped at the read sites, default 3650 —
    /// how many items the "Recently added" virtual playlist shows).
    var defaultRecentlyAddedCount: Int?
    /// LEGACY (pre-rename check builds persisted "local"/"remote") — decode-only; new blobs
    /// write `appleMusicPrivateSync` and nil here.
    var appleMusicSyncMode: String?
    /// Optional so older blobs still decode (nil ⇒ captured at init: private iff an import
    /// server is configured). The Private-syncing toggle.
    var appleMusicPrivateSync: Bool?
    /// Optional AND tri-state-meaningful: nil = the user never touched the Explicit-versions
    /// toggle (UNSET — existing songs stream their primary cut untouched); false/true = an
    /// explicit clean/explicit preference. Never coalesced at the persistence layer.
    var preferExplicitVersions: Bool?
    /// Optional so older blobs still decode (coalesced to FALSE — two-way favorites sync is a
    /// deliberate opt-in).
    var favoritesTwoWaySync: Bool?
    /// Optional so older blobs still decode (coalesced to FALSE — owner-seed adoption is opt-in).
    var applyOwnerFavoritesSeed: Bool?
    /// Optional so older blobs still decode (coalesced to TRUE — daily auto-sync is on unless
    /// turned off).
    var amAutoSyncEnabled: Bool?
    var amImportNewPlaylists: Bool?
    /// Optional so older blobs still decode (coalesced to 980 = 4:20 PM local).
    var amAutoSyncMinutes: Int?
    /// Optional — epoch ms of the last auto-sync claim.
    var lastAMAutoSyncAtMs: Double?

    static let `default` = SettingsData(
        sources: [SourceConfig(name: "My Vinyl", urlString: Config.indexURL.absoluteString)],
        // #TOUPDATE: no shipped default rip/jukebox server URL — seeded BLANK so `hasServer`
        // is honestly false out of the box (server features show "No rip server configured"
        // until the user sets a URL). This also keeps the old personal-tailnet hostname out of
        // the shipped binary. Set these to the first-party PocketDJ cloud endpoint once it exists.
        ripServerURL: "",
        ripToken: "",
        jukeboxServerURL: "",
        jukeboxToken: "",
        jukeboxTokensRequiredByDefault: true,
        ripFromCloud: false,
        playbackMode: PlaybackMode.cloud.rawValue,
        searchAccessKeyID: "",
        searchSecretKey: "",
        searchEndpoint: "",
        burnFolderBookmark: nil,
        sessionFolderBookmark: nil,
        autoMixLeadSeconds: 15,
        autoMixFadeSeconds: 3,
        skipFadeSeconds: 15,
        mixGlideSeconds: 10,
        mixAutoHidePlayed: true,
        cueOutputChannel: CueChannel.right.rawValue,
        beatPulseEnabled: false,
        mixDeckLayout: MixDeckLayout.stacked.rawValue,
        collectionSort: nil,
        lastSection: nil,
        storageSoftCapGB: nil,
        lastStoragePruneAt: nil,
        debugLoggingEnabled: nil,
        samplesFolderBookmark: nil,
        loopsFolderBookmark: nil,
        sequencesFolderBookmark: nil,
        takesFolderBookmark: nil,
        pocketDJName: nil,
        studioTab: nil,
        studioClickEnabled: nil,
        studioCountInEnabled: nil,
        syncConvertedPockets: nil,
        cloudSyncEnabled: nil,
        writeBackBackfillDays: nil,
        defaultRecentlyAddedCount: nil,
        appleMusicSyncMode: nil,
        appleMusicPrivateSync: nil,
        preferExplicitVersions: nil,
        favoritesTwoWaySync: nil,
        applyOwnerFavoritesSeed: nil,
        amAutoSyncEnabled: nil,
        amImportNewPlaylists: nil,
        amAutoSyncMinutes: nil,
        lastAMAutoSyncAtMs: nil)
}
