import Foundation
import Observation

/// Location permission as the store/UI sees it — CoreLocation-free so it compiles everywhere.
enum ListeningLocationAuthorization: String, Codable, Sendable {
    case notDetermined, denied, restricted, whenInUse, always
    /// No location source on this platform.
    case unsupported

    var isGranted: Bool { self == .whenInUse || self == .always }
}

/// Where visits + movement come from. iOS: `CoreLocationVisitSource`. Tests inject a fake, which
/// is also how the permission-denied path is exercised without a real prompt.
@MainActor
protocol ListeningLocationSource: AnyObject {
    var authorization: ListeningLocationAuthorization { get }
    /// Begin monitoring, delivering into `store` (asks When-In-Use first if undetermined).
    func start(delivering store: ListeningLocationStore)
    func stop()
    /// Offer the When-In-Use → Always upgrade (iOS shows that prompt at most once).
    func requestAlwaysUpgrade()
}

/// The on-device location context engine (design spec §3.3): owns a persisted
/// `ListeningPlaceEngine`, implements `ListeningContextProviding` for the play-history →
/// listening-pockets pipeline, and (iOS only) drives the CoreLocation source.
///
/// OPT-IN, default OFF. The document lives in Application Support
/// `pocketdj-listening-places.json`: atomic writes, `.completeUntilFirstUserAuthentication`
/// (a visit can relaunch the app in the background while the device is locked), excluded from
/// backup, and NEVER registered with CloudSyncService — coordinates never leave the device.
/// Turning it off erases everything; plays already tagged keep their opaque ids, which then read
/// as "Earlier place".
///
/// The class is cross-platform; on macOS/tvOS/visionOS `isSupported == false`, every lookup is
/// `.unavailable`, and nothing is ever ingested.
@MainActor
@Observable
final class ListeningLocationStore: ListeningContextProviding {

    nonisolated static let schemaVersion = 1

    #if os(iOS)
    nonisolated static let platformSupportsLocation = true
    #else
    nonisolated static let platformSupportsLocation = false
    #endif

    /// The opt-in (default false), persisted in this store's own document.
    private(set) var isEnabled: Bool = false
    /// Current permission (`.unsupported` off iOS; mirrors the source while one runs).
    private(set) var authorization: ListeningLocationAuthorization
    /// Whether the When-In-Use → Always upgrade prompt was already offered (iOS shows it once;
    /// after that the only way is the Settings app).
    private(set) var didRequestAlways: Bool = false
    private(set) var revision: Int = 0
    /// The engine state (read-only to the UI; every mutation goes through this store).
    private(set) var engine = ListeningPlaceEngine()

    let isSupported: Bool
    var isActive: Bool { isSupported && isEnabled && authorization.isGranted }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeSource: @MainActor () -> ListeningLocationSource?
    @ObservationIgnored private var source: ListeningLocationSource?

    /// `platformSupported` / `makeSource` are test seams (defaults: this platform; on iOS the
    /// real `CoreLocationVisitSource`).
    init(fileURL: URL = ListeningLocationStore.defaultURL(), now: @escaping () -> Date = Date.init,
         platformSupported: Bool = ListeningLocationStore.platformSupportsLocation,
         makeSource: (@MainActor () -> ListeningLocationSource?)? = nil) {
        self.fileURL = fileURL
        self.now = now
        self.isSupported = platformSupported
        self.makeSource = makeSource ?? ListeningLocationStore.platformSource
        self.authorization = platformSupported ? .notDetermined : .unsupported
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            isEnabled = doc.isEnabled && platformSupported
            didRequestAlways = doc.didRequestAlways
            engine = doc.engine
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-listening-places.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (never the user's real places).
    /// Mirrors PlayHistoryStore.launchURL.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-listening-places.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private static func platformSource() -> ListeningLocationSource? {
        #if os(iOS)
        return CoreLocationVisitSource()
        #else
        return nil
        #endif
    }

    // MARK: - Lifecycle

    /// Call once from `PocketDJApp.init`. Creating the source HERE (not lazily from a view) is
    /// what makes a background relaunch for a visit deliver into a live delegate.
    func startIfEnabled() {
        guard isSupported, isEnabled else { return }
        engine.prune(now: now())
        save()
        startSource()
    }

    /// On: start tracking now, ask for permission, start the source. Off: stop + erase.
    func setEnabled(_ on: Bool) {
        guard isSupported else { return }
        if on {
            guard !isEnabled else { startSource(); return }
            isEnabled = true
            if engine.trackingStartedAt == nil { engine.trackingStartedAt = now() }
            bump()
            startSource()
        } else {
            source?.stop()
            source = nil
            isEnabled = false
            authorization = .notDetermined
            didRequestAlways = false
            eraseAll()
        }
    }

    /// Wipe every place, trip and visit. While still enabled, tracking restarts from now (so
    /// times before the erase read `.unavailable`, not "nowhere").
    func eraseAll() {
        engine = ListeningPlaceEngine()
        if isEnabled { engine.trackingStartedAt = now() }
        bump()
    }

    /// Settings' "Allow Always" button (the system shows that prompt at most once).
    func requestAlwaysUpgrade() {
        guard isSupported, isEnabled, let source else { return }
        didRequestAlways = true
        bump()
        source.requestAlwaysUpgrade()
    }

    private func startSource() {
        if source == nil { source = makeSource() }
        guard let source else { return }
        authorization = source.authorization
        source.start(delivering: self)
    }

    // MARK: - Source callbacks

    func sourceAuthorizationDidChange(_ status: ListeningLocationAuthorization) {
        guard isSupported, status != authorization else { return }
        let wasGranted = authorization.isGranted
        authorization = status
        // Tracking effectively begins at the grant: if nothing was observed yet, times between
        // "enabled" and "granted" stay `.unavailable` instead of settling to "nowhere".
        if isEnabled, status.isGranted, !wasGranted, engine.timeline.isEmpty {
            engine.trackingStartedAt = now()
        }
        bump()
    }

    func ingestVisit(_ visit: LocationVisitSample) {
        guard isSupported, isEnabled else { return }
        engine.ingest(visit, now: now())
        bump()
    }

    func noteMovement(_ fix: LocationFixSample) {
        guard isSupported, isEnabled else { return }
        engine.noteMovement(fix, now: now())
        bump()
    }

    // MARK: - ListeningContextProviding

    func context(at date: Date) -> ListeningContextLookup {
        guard isActive else { return .unavailable }
        return engine.lookup(at: date, now: now())
    }

    func currentContextGuess() -> ListeningContextTag? {
        guard isActive else { return nil }
        return engine.currentGuess(now: now())
    }

    func placeLabels() -> [ListeningPlaceLabel] {
        guard isSupported, isEnabled else { return [] }
        return engine.rankedPlaces(now: now())
    }

    func tripLabels() -> [ListeningTripLabel] {
        guard isSupported, isEnabled else { return [] }
        return engine.trips(now: now())
    }

    func label(for tag: ListeningContextTag) -> String? {
        guard isSupported, isEnabled else { return nil }
        return engine.label(for: tag, now: now())
    }

    // MARK: - Persistence

    private func bump() {
        revision &+= 1
        save()
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var isEnabled: Bool
        var didRequestAlways: Bool
        var engine: ListeningPlaceEngine

        init(schemaVersion: Int, isEnabled: Bool, didRequestAlways: Bool, engine: ListeningPlaceEngine) {
            self.schemaVersion = schemaVersion; self.isEnabled = isEnabled
            self.didRequestAlways = didRequestAlways; self.engine = engine
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, isEnabled, didRequestAlways, engine }

        /// Lenient: a damaged field falls back to its default (off / empty), never a crash.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? ListeningLocationStore.schemaVersion
            isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false
            didRequestAlways = (try? c.decode(Bool.self, forKey: .didRequestAlways)) ?? false
            engine = (try? c.decode(ListeningPlaceEngine.self, forKey: .engine)) ?? ListeningPlaceEngine()
        }
    }

    private func save() {
        let doc = Document(schemaVersion: Self.schemaVersion, isEnabled: isEnabled,
                           didRequestAlways: didRequestAlways, engine: engine)
        guard let data = try? JSONEncoder().encode(doc) else { return }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        guard (try? data.write(to: fileURL, options: options)) != nil else { return }
        // An atomic write replaces the file, so the backup exclusion is re-applied every save.
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
