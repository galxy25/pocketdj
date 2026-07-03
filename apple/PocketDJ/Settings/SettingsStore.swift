import SwiftUI
import Observation

/// Global device/cloud playback mode (Item 7 — fully wired by Native2/Server). Defined
/// here as the natural home; the `SetlistPlayer.playbackMode` seam already consumes it.
///   • `.cloud`  — stream (Apple Music → rip-on-demand fallback), today's behaviour.
///   • `.device` — play from burned local files (fall back to cloud for a missing file).
enum PlaybackMode: String, Codable, Hashable, Sendable { case cloud, device }

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

    private let defaults: UserDefaults
    private static let key = "pdj.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = SettingsStore.load(from: defaults)
        self.sources = data.sources
        self.ripServerURL = data.ripServerURL
        self.ripToken = data.ripToken
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
        self.lastSection = data.lastSection
        self.storageSoftCapGB = data.storageSoftCapGB
        self.lastStoragePruneAt = data.lastStoragePruneAt
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
            ripFromCloud: ripFromCloud, playbackMode: playbackMode.rawValue,
            searchAccessKeyID: searchAccessKeyID, searchSecretKey: searchSecretKey,
            searchEndpoint: searchEndpoint, burnFolderBookmark: burnFolderBookmark,
            sessionFolderBookmark: sessionFolderBookmark,
            autoMixLeadSeconds: autoMixLeadSeconds, autoMixFadeSeconds: autoMixFadeSeconds,
            skipFadeSeconds: skipFadeSeconds, mixGlideSeconds: mixGlideSeconds,
            mixAutoHidePlayed: mixAutoHidePlayed,
            cueOutputChannel: cueOutputChannel.rawValue,
            beatPulseEnabled: beatPulseEnabled,
            lastSection: lastSection,
            storageSoftCapGB: storageSoftCapGB,
            lastStoragePruneAt: lastStoragePruneAt)
        if let encoded = try? JSONEncoder().encode(snapshot) {
            defaults.set(encoded, forKey: SettingsStore.key)
        }
    }

    /// Wipe ALL on-device state: settings, the URL cache (covers + index), the per-source
    /// catalog disk cache, back to defaults.
    func resetEverything() {
        defaults.removeObject(forKey: SettingsStore.key)
        URLCache.shared.removeAllCachedResponses()
        // Also drop CatalogService's persistent offline cache — otherwise a "reset" still
        // serves the last-good index for each source on the next failed fetch.
        if let dir = CatalogService.cacheDirectory() { try? FileManager.default.removeItem(at: dir) }
        let d = SettingsData.default
        sources = d.sources
        ripServerURL = d.ripServerURL; ripToken = d.ripToken
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
        lastSection = d.lastSection
        storageSoftCapGB = d.storageSoftCapGB
        lastStoragePruneAt = d.lastStoragePruneAt
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
    /// Optional so older blobs still decode (nil = never persisted = home).
    var lastSection: String?
    /// Storage soft cap in decimal GB. Optional-by-design even when current: nil IS the
    /// meaningful default (no cap ⇒ no automatic storage management).
    var storageSoftCapGB: Double?
    /// Optional so older blobs still decode (nil = the daily prune has never run).
    var lastStoragePruneAt: Double?

    static let `default` = SettingsData(
        sources: [SourceConfig(name: "My Vinyl", urlString: Config.indexURL.absoluteString)],
        ripServerURL: Config.ripServerBase.absoluteString,
        ripToken: "",
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
        lastSection: nil,
        storageSoftCapGB: nil,
        lastStoragePruneAt: nil)
}
