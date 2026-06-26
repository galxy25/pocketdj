import SwiftUI
import Observation

/// Global device/cloud playback mode (Item 7 — fully wired by Native2/Server). Defined
/// here as the natural home; the `SetlistPlayer.playbackMode` seam already consumes it.
///   • `.cloud`  — stream (Apple Music → rip-on-demand fallback), today's behaviour.
///   • `.device` — play from burned local files (fall back to cloud for a missing file).
enum PlaybackMode: String, Codable, Hashable, Sendable { case cloud, device }

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
    /// Auto-Mix (Mix tab): seconds BEFORE a track ends to begin crossfading to the next deck.
    /// Default 15. Read when the user starts an auto-mix; clamped to a sane range in the UI.
    var autoMixLeadSeconds: Double
    /// Auto-Mix (Mix tab): duration in seconds of the crossfade (volume sweep) between decks.
    /// Default 3.
    var autoMixFadeSeconds: Double

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
        self.autoMixLeadSeconds = data.autoMixLeadSeconds ?? 15
        self.autoMixFadeSeconds = data.autoMixFadeSeconds ?? 3
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
            autoMixLeadSeconds: autoMixLeadSeconds, autoMixFadeSeconds: autoMixFadeSeconds)
        if let encoded = try? JSONEncoder().encode(snapshot) {
            defaults.set(encoded, forKey: SettingsStore.key)
        }
    }

    /// Wipe ALL on-device state: settings, the URL cache (covers + index), back to defaults.
    func resetEverything() {
        defaults.removeObject(forKey: SettingsStore.key)
        URLCache.shared.removeAllCachedResponses()
        let d = SettingsData.default
        sources = d.sources
        ripServerURL = d.ripServerURL; ripToken = d.ripToken
        ripFromCloud = d.ripFromCloud ?? false
        playbackMode = d.playbackMode.flatMap(PlaybackMode.init(rawValue:)) ?? .cloud
        searchAccessKeyID = d.searchAccessKeyID; searchSecretKey = d.searchSecretKey
        searchEndpoint = d.searchEndpoint
        burnFolderBookmark = d.burnFolderBookmark
        autoMixLeadSeconds = d.autoMixLeadSeconds ?? 15
        autoMixFadeSeconds = d.autoMixFadeSeconds ?? 3
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
    /// Optional so older blobs still decode (coalesced to 15 / 3 at the read sites).
    var autoMixLeadSeconds: Double?
    var autoMixFadeSeconds: Double?

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
        autoMixLeadSeconds: 15,
        autoMixFadeSeconds: 3)
}
