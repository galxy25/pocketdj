import Foundation

/// iCloud-SYNCED settings — the connection/credential subset of `SettingsStore` that follows
/// the user's Apple ID across devices (Mac ⇄ iPhone ⇄ iPad ⇄ Apple TV ⇄ Vision Pro), so the
/// rip server, Jukebox Hero broker, and online-search credentials are entered ONCE and every
/// other device picks them up (the Apple TV app never grows a credential-typing flow).
///
/// Rides the EXISTING `CloudSyncService` document machinery (whole-document LWW against one
/// `PDJDoc` record in the user's private CloudKit DB) instead of inventing a parallel channel:
///   • `SettingsStore.persist()` mirrors this subset into an Application Support JSON file
///     (`pocketdj-settings-credentials.json`) — but only when the CONTENT changed (byte
///     compare against a sorted-keys encoding), so the file's mtime means "last credential
///     edit", not "last time any setting persisted" (`lastSection` persists on every tab
///     switch; a naive write would push this doc on every sync pass).
///   • PocketDJApp registers the file as the "settings-credentials" cloud doc; a pull
///     rewrites the file and `reloadCredentialsFromDisk()` applies it to the live store and
///     re-persists to UserDefaults. Registration precedes `syncAtLaunch`, so a fresh device
///     adopts the cloud credentials in the same launch pass as every other synced doc —
///     BEFORE any settings-dependent restore reads them.
///   • BLANK-FIELD DOCTRINE: a fresh install (all-blank subset, no file yet) never
///     materializes the doc, so it can never LWW-race the cloud copy — an empty local
///     install ADOPTS the cloud credentials. Once the file exists, a newer local edit (even
///     back to blank) wins per whole-document LWW, exactly like every other synced doc.
///   • DEVICE-SPECIFIC settings never ride along: folder bookmarks (security-scoped, only
///     valid on the minting device), local paths, playback mode, UI prefs, storage caps,
///     schedules — the document is this explicit field list and nothing else.
///   • Respects Settings ▸ Sync: the doc moves through the same `CloudSyncService` whose
///     `enabled` closure reads `cloudSyncEnabled` — toggle off ⇒ no push, no pull.
struct SettingsCredentialsDocument: Codable, Equatable {
    var schemaVersion: Int = 1
    var ripServerURL: String
    var ripToken: String
    var jukeboxServerURL: String
    var jukeboxToken: String
    var jukeboxTokensRequiredByDefault: Bool
    var searchAccessKeyID: String
    var searchSecretKey: String
    var searchEndpoint: String
    /// Tri-state on purpose (mirrors `appleMusicPrivateSyncRaw`): a nil from an older doc
    /// rides through decode without clobbering the receiving device's captured default.
    var appleMusicPrivateSync: Bool?
}

extension SettingsStore {

    nonisolated static func credentialsSyncDefaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-settings-credentials.json")
    }

    /// Under tests (PDJ_USE_FIXTURE — the unit-test scheme sets it globally) use an isolated,
    /// freshly-cleared file: a test run must never write fixture credentials into the user's
    /// REAL mirror, which a later real launch would push to the real iCloud account and LWW
    /// onto every device. Mirrors `ProfileStore.launchURL`.
    nonisolated static func credentialsSyncLaunchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-settings-credentials.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return credentialsSyncDefaultURL()
    }

    /// The synced subset as it stands in the live store.
    var credentialsDocument: SettingsCredentialsDocument {
        SettingsCredentialsDocument(
            ripServerURL: ripServerURL, ripToken: ripToken,
            jukeboxServerURL: jukeboxServerURL, jukeboxToken: jukeboxToken,
            jukeboxTokensRequiredByDefault: jukeboxTokensRequiredByDefault,
            searchAccessKeyID: searchAccessKeyID, searchSecretKey: searchSecretKey,
            searchEndpoint: searchEndpoint,
            appleMusicPrivateSync: appleMusicPrivateSyncRaw)
    }

    /// Every user-entered synced field at its fresh-install value ⇒ the doc must not
    /// materialize (the blank-field doctrine above). `appleMusicPrivateSync` is deliberately
    /// ignored: it's a derived install-time capture, not something the user typed.
    private var credentialsAreBlank: Bool {
        ripServerURL.isEmpty && ripToken.isEmpty
            && jukeboxServerURL.isEmpty && jukeboxToken.isEmpty
            && jukeboxTokensRequiredByDefault
            && searchAccessKeyID.isEmpty && searchSecretKey.isEmpty && searchEndpoint.isEmpty
    }

    /// Deterministic bytes (sorted keys) so equal content encodes identically on EVERY device —
    /// both the content compare below and the pull→re-persist round trip depend on it: the
    /// re-encode of just-pulled values must be byte-identical, or every pull would re-dirty
    /// the file (mtime bump ⇒ watermark cleared) and LWW would ping-pong the doc between
    /// devices forever.
    private nonisolated static func encodeCredentials(_ doc: SettingsCredentialsDocument) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(doc)
    }

    /// Mirror the subset to disk IFF its content changed. Called from `persist()` and once at
    /// the end of init (an already-configured device materializes the doc on first launch
    /// after the update, without waiting for the next settings edit).
    func syncCredentialsDocumentIfChanged() {
        guard let data = Self.encodeCredentials(credentialsDocument) else { return }
        let existing = try? Data(contentsOf: credentialsSyncFileURL)
        if existing == data { return }                          // unchanged ⇒ mtime untouched
        if existing == nil && credentialsAreBlank { return }    // blank install ⇒ adopt, don't race
        try? data.write(to: credentialsSyncFileURL, options: .atomic)
    }

    /// Re-decode the on-disk doc after `CloudSyncService` pulled a newer cloud copy, apply it
    /// to the live store, and re-persist so the UserDefaults blob agrees with the pull.
    /// Whole-document apply — the pull already won LWW. The nested `persist()` re-encodes
    /// byte-identical content, so the file's mtime stays the pull's (no push-back loop).
    func reloadCredentialsFromDisk() {
        guard let data = try? Data(contentsOf: credentialsSyncFileURL),
              let doc = try? JSONDecoder().decode(SettingsCredentialsDocument.self, from: data)
        else { return }
        ripServerURL = doc.ripServerURL
        ripToken = doc.ripToken
        jukeboxServerURL = doc.jukeboxServerURL
        jukeboxToken = doc.jukeboxToken
        jukeboxTokensRequiredByDefault = doc.jukeboxTokensRequiredByDefault
        searchAccessKeyID = doc.searchAccessKeyID
        searchSecretKey = doc.searchSecretKey
        searchEndpoint = doc.searchEndpoint
        if let priv = doc.appleMusicPrivateSync { appleMusicPrivateSyncRaw = priv }
        persist()
    }
}
