import SwiftUI
import Observation

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
    var searchAccessKeyID: String
    var searchSecretKey: String
    var searchEndpoint: String

    private let defaults: UserDefaults
    private static let key = "pdj.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = SettingsStore.load(from: defaults)
        self.sources = data.sources
        self.ripServerURL = data.ripServerURL
        self.ripToken = data.ripToken
        self.ripFromCloud = data.ripFromCloud ?? false
        self.searchAccessKeyID = data.searchAccessKeyID
        self.searchSecretKey = data.searchSecretKey
        self.searchEndpoint = data.searchEndpoint
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
            ripFromCloud: ripFromCloud,
            searchAccessKeyID: searchAccessKeyID, searchSecretKey: searchSecretKey,
            searchEndpoint: searchEndpoint)
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
        searchAccessKeyID = d.searchAccessKeyID; searchSecretKey = d.searchSecretKey
        searchEndpoint = d.searchEndpoint
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
    var searchAccessKeyID: String
    var searchSecretKey: String
    var searchEndpoint: String

    static let `default` = SettingsData(
        sources: [SourceConfig(name: "My Vinyl", urlString: Config.indexURL.absoluteString)],
        ripServerURL: Config.ripServerBase.absoluteString,
        ripToken: "",
        ripFromCloud: false,
        searchAccessKeyID: "",
        searchSecretKey: "",
        searchEndpoint: "")
}
