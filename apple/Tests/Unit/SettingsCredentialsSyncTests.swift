import XCTest
@testable import PocketDJ

/// The "settings-credentials" cloud doc — the `SettingsStore` connection/credential subset
/// that follows the Apple ID (rip server, Jukebox Hero broker, online-search credentials) —
/// driven end-to-end through the real `CloudSyncService` against an in-memory database
/// (no CloudKit, no account, no network — the CloudSyncServiceTests idiom).
@MainActor
final class SettingsCredentialsSyncTests: XCTestCase {

    /// In-memory stand-in for the CloudKit private DB.
    actor MemoryDB: CloudDocDatabase {
        var docs: [String: CloudDoc] = [:]
        var saveCount = 0
        func accountAvailable() async -> Bool { true }
        func fetchMeta(keys: [String]) async throws -> [String: Double] {
            Dictionary(uniqueKeysWithValues: keys.compactMap { k in docs[k].map { (k, $0.modifiedAtMs) } })
        }
        func fetch(_ key: String) async throws -> CloudDoc? { docs[key] }
        func save(_ doc: CloudDoc) async throws { docs[doc.key] = doc; saveCount += 1 }
        func delete(_ key: String) async throws { docs[key] = nil }
        func deleteAll(_ keys: [String]) async throws { for k in keys { docs[k] = nil } }
        func seed(_ key: String, payload: Data, modifiedAtMs: Double) {
            docs[key] = CloudDoc(key: key, payload: payload, modifiedAtMs: modifiedAtMs, deviceName: "seed")
        }
    }

    private var tempDir: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-credsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        for s in suites { UserDefaults(suiteName: s)?.removePersistentDomain(forName: s) }
    }

    private func makeStore(_ name: String) -> SettingsStore {
        let suite = "credsync.\(name).\(UUID().uuidString)"
        suites.append(suite)
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: d,
                             credentialsFileURL: tempDir.appendingPathComponent("\(name)-credentials.json"))
    }

    private func makeService(db: MemoryDB, enabled: Bool = true, name: String = "svc") -> CloudSyncService {
        CloudSyncService(database: db, enabled: { enabled },
                         stateURL: tempDir.appendingPathComponent("\(name)-state.json"))
    }

    private func register(_ store: SettingsStore, with svc: CloudSyncService) {
        svc.register("settings-credentials", fileURL: store.credentialsSyncFileURL) { [weak store] in
            store?.reloadCredentialsFromDisk()
        }
    }

    /// Fill every synced field with distinctive values and persist (mirrors a user typing
    /// their servers/credentials into Settings on the first configured device).
    private func configure(_ s: SettingsStore) {
        s.ripServerURL = "https://rip.example.ts.net"
        s.ripToken = "rip-secret"
        s.jukeboxServerURL = "https://jb.example.ts.net/jukebox"
        s.jukeboxToken = "jb-secret"
        s.jukeboxTokensRequiredByDefault = false
        s.searchAccessKeyID = "AKIAEXAMPLE"
        s.searchSecretKey = "search-s3cr3t"
        s.searchEndpoint = "https://search.example.aoss.amazonaws.com"
        s.persist()
    }

    private func setMtime(_ url: URL, ms: Double) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: ms / 1000)], ofItemAtPath: url.path)
    }
    private func mtimeMs(_ url: URL) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    // MARK: - Field-subset round trip

    /// Device A enters credentials once; device B (fresh, blank) signs into the same account
    /// and picks them up — the whole point of the feature (esp. the Apple TV app).
    func testCredentialSubsetRoundTripsAcrossDevices() async throws {
        let db = MemoryDB()
        let a = makeStore("device-a")
        configure(a)
        let svcA = makeService(db: db, name: "a")
        register(a, with: svcA)
        await svcA.syncNow()
        let pushed = await db.docs["settings-credentials"]
        XCTAssertNotNil(pushed, "the configured device must publish its credential doc")

        let b = makeStore("device-b")
        XCTAssertEqual(b.ripServerURL, "", "fresh device starts blank")
        let svcB = makeService(db: db, name: "b")
        register(b, with: svcB)
        await svcB.syncNow()

        XCTAssertEqual(b.ripServerURL, "https://rip.example.ts.net")
        XCTAssertEqual(b.ripToken, "rip-secret")
        XCTAssertEqual(b.jukeboxServerURL, "https://jb.example.ts.net/jukebox")
        XCTAssertEqual(b.jukeboxToken, "jb-secret")
        XCTAssertEqual(b.jukeboxTokensRequiredByDefault, false)
        XCTAssertEqual(b.searchAccessKeyID, "AKIAEXAMPLE")
        XCTAssertEqual(b.searchSecretKey, "search-s3cr3t")
        XCTAssertEqual(b.searchEndpoint, "https://search.example.aoss.amazonaws.com")
        XCTAssertTrue(b.searchConfigured, "search must be usable with the adopted credentials")
    }

    /// A pull must survive relaunch: the reload re-persists into the UserDefaults blob, so a
    /// store constructed later from the SAME defaults suite sees the adopted credentials.
    func testPulledCredentialsPersistIntoUserDefaults() async throws {
        let db = MemoryDB()
        let a = makeStore("seed")
        configure(a)
        let svcA = makeService(db: db, name: "a")
        register(a, with: svcA)
        await svcA.syncNow()

        let suite = "credsync.relaunch.\(UUID().uuidString)"
        suites.append(suite)
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let credURL = tempDir.appendingPathComponent("relaunch-credentials.json")
        let b = SettingsStore(defaults: d, credentialsFileURL: credURL)
        let svcB = makeService(db: db, name: "b")
        register(b, with: svcB)
        await svcB.syncNow()
        XCTAssertEqual(b.ripToken, "rip-secret")

        let relaunched = SettingsStore(defaults: d, credentialsFileURL: credURL)
        XCTAssertEqual(relaunched.ripServerURL, "https://rip.example.ts.net",
                       "the pull must be durable in the settings blob, not just the live store")
        XCTAssertEqual(relaunched.searchSecretKey, "search-s3cr3t")
    }

    // MARK: - LWW conflict

    /// A NEWER local edit — even back to blank — wins over an older cloud doc (the user
    /// deliberately cleared a server; the cloud must not resurrect it).
    func testNewerLocalEditEvenToBlankWinsLWW() async throws {
        let db = MemoryDB()
        let store = makeStore("editor")
        configure(store)
        // The cloud holds an OLD doc with different values.
        let stale = SettingsCredentialsDocument(
            ripServerURL: "https://old.example", ripToken: "old-token",
            jukeboxServerURL: "", jukeboxToken: "", jukeboxTokensRequiredByDefault: true,
            searchAccessKeyID: "OLDKEY", searchSecretKey: "old", searchEndpoint: "",
            appleMusicPrivateSync: nil)
        await db.seed("settings-credentials", payload: try JSONEncoder().encode(stale),
                      modifiedAtMs: 1_000_000)
        // The user clears the rip server locally (a real edit, newer than the cloud doc).
        store.ripServerURL = ""
        store.ripToken = ""
        store.persist()

        let svc = makeService(db: db)
        register(store, with: svc)
        await svc.syncNow()

        XCTAssertEqual(store.ripServerURL, "", "the newer local blank must not be clobbered")
        let doc = await db.docs["settings-credentials"]
        let decoded = try JSONDecoder().decode(SettingsCredentialsDocument.self, from: XCTUnwrap(doc).payload)
        XCTAssertEqual(decoded.ripServerURL, "", "the blank edit must WIN in the cloud (LWW)")
        XCTAssertEqual(decoded.searchAccessKeyID, "AKIAEXAMPLE",
                       "the rest of the local doc rides up with it (whole-document LWW)")
    }

    /// A strictly newer cloud doc replaces an older local one wholesale.
    func testOlderLocalAdoptsNewerCloud() async throws {
        let db = MemoryDB()
        let store = makeStore("stale-local")
        configure(store)
        // Age the local mirror far into the past.
        setMtime(store.credentialsSyncFileURL, ms: 1_000_000)
        let fresh = SettingsCredentialsDocument(
            ripServerURL: "https://new.example", ripToken: "new-token",
            jukeboxServerURL: "https://new-jb.example", jukeboxToken: "new-jb",
            jukeboxTokensRequiredByDefault: true,
            searchAccessKeyID: "NEWKEY", searchSecretKey: "new-secret",
            searchEndpoint: "https://new-search.example",
            appleMusicPrivateSync: true)
        await db.seed("settings-credentials", payload: try JSONEncoder().encode(fresh),
                      modifiedAtMs: Date().timeIntervalSince1970 * 1000)

        let svc = makeService(db: db)
        register(store, with: svc)
        await svc.syncNow()

        XCTAssertEqual(store.ripServerURL, "https://new.example")
        XCTAssertEqual(store.ripToken, "new-token")
        XCTAssertEqual(store.jukeboxServerURL, "https://new-jb.example")
        XCTAssertEqual(store.searchAccessKeyID, "NEWKEY")
        XCTAssertEqual(store.appleMusicPrivateSync, true, "the synced private-sync capture applies")
    }

    // MARK: - Sync toggle off

    /// Settings ▸ Sync off ⇒ the credential doc neither pushes nor pulls.
    func testSyncOffMeansNoPushAndNoPull() async throws {
        let db = MemoryDB()
        let store = makeStore("sync-off")
        configure(store)
        let cloudDoc = SettingsCredentialsDocument(
            ripServerURL: "https://cloud.example", ripToken: "cloud",
            jukeboxServerURL: "", jukeboxToken: "", jukeboxTokensRequiredByDefault: true,
            searchAccessKeyID: "", searchSecretKey: "", searchEndpoint: "",
            appleMusicPrivateSync: nil)
        let payload = try JSONEncoder().encode(cloudDoc)
        await db.seed("settings-credentials", payload: payload,
                      modifiedAtMs: Date().timeIntervalSince1970 * 1000 + 60_000)

        let svc = makeService(db: db, enabled: false)
        register(store, with: svc)
        await svc.syncNow()
        await svc.pushDirty()

        XCTAssertEqual(store.ripServerURL, "https://rip.example.ts.net", "no pull while sync is off")
        let saves = await db.saveCount
        XCTAssertEqual(saves, 0, "no push while sync is off")
        let doc = await db.docs["settings-credentials"]
        XCTAssertEqual(doc?.payload, payload, "the cloud doc must be untouched")
    }

    // MARK: - Device-specific fields never serialized

    /// The doc is an explicit allow-list: bookmarks (security-scoped, device-only), playback
    /// mode, UI prefs, storage caps must NEVER appear in the serialized payload.
    func testDeviceSpecificFieldsNeverSerialized() async throws {
        let store = makeStore("subset")
        configure(store)
        store.burnFolderBookmark = Data([1, 2, 3])
        store.sessionFolderBookmark = Data([4, 5, 6])
        store.playbackMode = .device
        store.storageSoftCapGB = 5
        store.lastSection = "mix"
        store.pocketDJName = "DJ Test"
        store.persist()

        let data = try Data(contentsOf: store.credentialsSyncFileURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "schemaVersion",
            "ripServerURL", "ripToken",
            "jukeboxServerURL", "jukeboxToken", "jukeboxTokensRequiredByDefault",
            "searchAccessKeyID", "searchSecretKey", "searchEndpoint",
            "appleMusicPrivateSync",
            // Catalog sources ride along (Levi, on-TV 2026-09-02) — names + index URLs are
            // portable; nothing device-specific lives in SourceConfig.
            "sources",
        ]
        XCTAssertEqual(Set(json.keys), allowed,
                       "the synced doc must be exactly the credential subset — nothing device-specific")
    }

    // MARK: - Blank-install doctrine + mtime stability

    /// A fresh all-blank install must not materialize the doc (it would LWW-race and could
    /// clobber real cloud credentials with blanks); it ADOPTS the cloud copy instead.
    func testBlankInstallNeverMaterializesDocAndAdoptsCloud() async throws {
        let db = MemoryDB()
        let store = makeStore("fresh")
        store.lastSection = "browse"
        store.persist()   // a device-only persist must not create the doc either
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.credentialsSyncFileURL.path),
                       "an all-blank install must never materialize the credentials doc")

        let cloudDoc = SettingsCredentialsDocument(
            ripServerURL: "https://rip.example", ripToken: "tok",
            jukeboxServerURL: "", jukeboxToken: "", jukeboxTokensRequiredByDefault: true,
            searchAccessKeyID: "K", searchSecretKey: "S", searchEndpoint: "E",
            appleMusicPrivateSync: nil)
        await db.seed("settings-credentials", payload: try JSONEncoder().encode(cloudDoc),
                      modifiedAtMs: 1_000_000)   // even an OLD cloud doc beats no local file
        let svc = makeService(db: db)
        register(store, with: svc)
        await svc.syncNow()

        XCTAssertEqual(store.ripServerURL, "https://rip.example", "blank local adopts the cloud value")
        XCTAssertEqual(store.searchSecretKey, "S")
        let saves = await db.saveCount
        XCTAssertEqual(saves, 0, "adopting must not push anything back up")
    }

    /// Registered with CloudSyncService as "settings-credentials", so it MUST be in
    /// `AccountDeletionService.cloudDocKeys` — otherwise the user's rip/jukebox/search
    /// credentials would survive an account deletion in their private CloudKit DB
    /// (the TimelineCueStoreTests / RecSyncRoundTripTests doctrine).
    func testAccountDeletionCoversTheCredentialsDoc() {
        XCTAssertTrue(AccountDeletionService.cloudDocKeys.contains("settings-credentials"))
    }

    /// Persisting DEVICE-ONLY changes (tab switches, playback mode…) must not bump the doc's
    /// mtime — the mtime IS the LWW timestamp, so a bump would push a no-op doc on every pass.
    func testDeviceOnlyPersistsDoNotBumpDocMtime() throws {
        let store = makeStore("stable")
        configure(store)
        let before = try XCTUnwrap(mtimeMs(store.credentialsSyncFileURL))
        setMtime(store.credentialsSyncFileURL, ms: before - 10_000)   // detectable baseline
        let baseline = try XCTUnwrap(mtimeMs(store.credentialsSyncFileURL))
        store.lastSection = "producer"
        store.playbackMode = .device
        store.persist()
        store.persist()
        XCTAssertEqual(mtimeMs(store.credentialsSyncFileURL), baseline,
                       "unchanged credential content must leave the doc's mtime untouched")
    }
}
