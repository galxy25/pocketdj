import Foundation
import Observation
import Network

// ============================================================================
// MARK: - The add port (the seam tests fake)
// ============================================================================

/// What the like-adder needs from the outside world: ONE album add, ONE write-only retry, and
/// whether a failed add looks like "no connection". A protocol so the unit tests drive the whole
/// state machine with a counting fake and never touch MusicKit, the network or `RipsStore`.
@MainActor
protocol ReleaseAddPort: AnyObject {
    /// The album page's add (`RipsStore.addRelease`): Apple Music library write + provisional
    /// catalog album, `.libraryOnly` — a like NEVER captures audio.
    func add(_ release: LikedRelease) async -> ReleaseAddReport
    /// Re-run ONLY the Apple Music write for an album that is already recorded.
    func retryWrite(_ release: LikedRelease) async -> ReleaseAddReport
    /// Whether a nothing-recorded failure should read as "offline" (retry later by itself) rather
    /// than a real failure (wait for his tap).
    var isOffline: Bool { get }
}

/// The production port: the album page's own add, through the first Apple Music contributor.
@MainActor
final class RipsReleaseAddPort: ReleaseAddPort {
    private let rips: RipsStore
    private let library: () -> (any MusicLibraryContributor)?
    private let reachability = NetworkReachability()

    init(rips: RipsStore, library: @escaping () -> (any MusicLibraryContributor)?) {
        self.rips = rips; self.library = library
    }

    func add(_ release: LikedRelease) async -> ReleaseAddReport {
        // Already recorded (the album page, an earlier add, another device's Discover add) with
        // an Apple Music write that isn't proven: the heal is the write alone. Re-running the
        // whole add would re-expand the tracks to change nothing.
        if let e = rips.discoverAdds?.album(forAppleMusicId: release.storeId),
           !AppleMusicLibraryWriteOutcome.provenByToken(e.libraryWrite) {
            return await retryWrite(release)
        }
        return await rips.addRelease(ref: release.albumRef, trackCount: release.trackCount,
                                     library: library())
    }

    func retryWrite(_ release: LikedRelease) async -> ReleaseAddReport {
        let lib = library()
        let outcome = await rips.retryAlbumLibraryWrite(albumId: "amrec_album_\(release.storeId)",
                                                        appleMusicId: release.storeId, library: lib)
        return ReleaseAddReport(
            write: outcome, recorded: true,
            error: RipsStore.libraryWriteSurfaceNotice(outcome, noun: "album", hadLibrary: lib != nil))
    }

    var isOffline: Bool {
        !reachability.isOnline || (!rips.hasServer && !(library()?.canContribute ?? false))
    }
}

/// A path snapshot, optimistic until the first update. A class (not a struct) because the monitor
/// callback runs on its own queue.
final class NetworkReachability: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.online = path.status == .satisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.levi.pocketdj.like-add-reach", qos: .utility))
    }
    deinit { monitor.cancel() }
    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }
}

/// UI-test port (double-gated with `ReleaseFeedService.wantsUIFixture`): succeeds, and records an
/// empty provisional album so the ownership probe flips exactly as a real add's would — the
/// suite proves the row leaves the screen without ever touching MusicKit.
@MainActor
final class FixtureReleaseAddPort: ReleaseAddPort {
    private let adds: DiscoverAddsStore?
    init(adds: DiscoverAddsStore?) { self.adds = adds }

    func add(_ release: LikedRelease) async -> ReleaseAddReport {
        adds?.addAlbumBatch(albumId: "amrec_album_\(release.storeId)", appleMusicId: release.storeId,
                            title: release.title ?? "Album", artist: release.artistName,
                            trackIds: [], artworkUrl: release.artworkUrl, trackCount: release.trackCount,
                            libraryWrite: AppleMusicLibraryWriteOutcome.confirmedToken, songs: [])
        return ReleaseAddReport(write: .confirmed, recorded: true, error: nil)
    }
    func retryWrite(_ release: LikedRelease) async -> ReleaseAddReport { await add(release) }
    var isOffline: Bool { false }
}

// ============================================================================
// MARK: - The adder
// ============================================================================

/// A 👍 on a For You ▸ New row ADDS THE RECORD, and anything he liked but never added can be added
/// from the "Liked — not added" section. Screen-independent: it is app-scoped, so leaving the New
/// screen mid-add cancels nothing.
///
/// ── THE RULES (design: docs/design/foryou-new-like-adds.md) ──────────────────────────────────
///  • The verdict is recorded FIRST by `RecFeedbackButtons` and is never rolled back by a failed
///    add. The taste signal and the collection are two different things he asked for.
///  • An add runs ONCE per 👍: the button only calls `liked` when the verdict landed `.accepted`
///    (an undo never adds), and `inFlight` swallows a double tap.
///  • Un-👍 never removes anything from the library. It only cancels an add still QUEUED behind
///    "Add all"; an in-flight add completes.
///  • Offline adds retry by themselves (`sweep`); real failures wait for his Retry tap.
///  • Old likes are only SURFACED with an Add button — never bulk-added silently.
@MainActor
@Observable
final class NewReleaseLikeAdder {

    nonisolated static let offlineMessage = "Will add when you’re back online"
    /// A release is retried by the sweep at most once per this window.
    nonisolated static let sweepThrottleMs: Double = 6 * 3_600_000
    nonisolated static let hydrateBatch = ReleaseFeedPolicy.idsPerRequest

    /// storeIds with an add running right now.
    private(set) var inFlight: Set<String> = []
    /// storeIds waiting behind a running "Add all" — shown as busy, cancellable by an un-👍.
    private(set) var queued: Set<String> = []
    private(set) var isAddingAll = false

    @ObservationIgnored let store: LikedReleasesStore
    @ObservationIgnored private let port: ReleaseAddPort
    @ObservationIgnored private let transport: ReleaseFeedTransport?
    @ObservationIgnored private let clock: () -> Double
    /// Is this release owned by ANY path? The SAME probes the feed uses (set at composition).
    @ObservationIgnored var isOwned: ((LikedRelease) -> Bool)?
    /// The accepted `new`-scope verdicts, for pruning and the sweep's "still liked?" check.
    @ObservationIgnored var acceptedProvider: (() -> [String: Double])?

    init(store: LikedReleasesStore, port: ReleaseAddPort, transport: ReleaseFeedTransport? = nil,
         clock: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.store = store; self.port = port; self.transport = transport; self.clock = clock
    }

    // MARK: outcome → state (pure — the table in the design, §1.3)

    struct Outcome: Equatable {
        var state: LikeAddState
        var message: String?
    }

    /// Whether this platform can write the Apple Music library at all (macOS cannot — the
    /// album page opens Music.app there instead, and a 👍 deliberately never does).
    nonisolated static var platformCanWrite: Bool {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }

    /// Every row of the outcome table:
    ///  • recorded + proven write → added
    ///  • recorded + macOS skip (nothing the platform can do) → added
    ///  • recorded + unproven write → failed, with the album page's own wording + a Retry that
    ///    re-runs only the write
    ///  • nothing recorded, release in the future → awaitingRelease (pre-order: tried now, re-run
    ///    on release day — whether or not the write landed)
    ///  • nothing recorded, offline → offline (the sweep retries)
    ///  • nothing recorded, anything else → failed with the honest message
    static func state(for report: ReleaseAddReport, releaseAtMs: Double?, nowMs: Double,
                                  offline: Bool = false,
                                  canWrite: Bool = NewReleaseLikeAdder.platformCanWrite) -> Outcome {
        if report.recorded {
            if report.write.isConfirmed { return Outcome(state: .added, message: nil) }
            if case .skipped = report.write, !canWrite { return Outcome(state: .added, message: nil) }
            let msg = report.error ?? RipsStore.libraryWriteNotice(report.write, noun: "album")
            return Outcome(state: .failed, message: msg)
        }
        if let at = releaseAtMs, at > nowMs {
            return Outcome(state: .awaitingRelease, message: nil)
        }
        if offline { return Outcome(state: .offline, message: offlineMessage) }
        return Outcome(state: .failed, message: report.error ?? "Couldn’t add this record — try again.")
    }

    // MARK: 👍

    /// A 👍 landed `.accepted` on a New row: remember the release and add it. No-op for a row with
    /// no release id (a `relartist:` like stays pure feedback).
    ///
    /// Returns the add's task so a test can await it; callers ignore it. The id goes into `queued`
    /// SYNCHRONOUSLY, so the row is already "busy" on the very next render — without that, the
    /// New screen would flash the just-liked record in "Liked — not added" with an idle Add button
    /// for the one main-actor hop before the add starts.
    @discardableResult
    func liked(_ entry: ArtistReleaseEntry) -> Task<Void, Never>? {
        guard var rel = LikedRelease(entry: entry, likedAtMs: clock()) else { return nil }
        // A fresh 👍 starts a fresh attempt history (the old one belongs to an earlier like).
        rel.attempt = nil
        store.upsert(rel)
        // Owned by another path already (the feed hides owned rows, but a stale row can be tapped):
        // nothing to add, and Retry-Apple-Music is the Liked section's job.
        if isOwned?(rel) == true { return nil }
        let id = rel.storeId
        queued.insert(id)
        return Task { [weak self] in
            guard let self else { return }
            // An un-👍 between the tap and this hop (or a queue cleared since) cancels the add.
            guard self.queued.contains(id), self.stillAccepted(id) else { self.queued.remove(id); return }
            await self.run(id, writeOnly: false)
        }
    }

    /// Un-👍: cancel an add still queued. Never touches the library; an in-flight add completes.
    func unliked(storeId: String) {
        queued.remove(storeId)
    }

    /// Is the verdict still `accepted`? Unknown (no provider — tests) reads as yes.
    private func stillAccepted(_ storeId: String) -> Bool {
        guard let accepted = acceptedProvider?() else { return true }
        return accepted["rel:\(storeId)"] != nil
    }

    // MARK: row buttons

    /// Add / Retry on a Liked row. `writeOnly` = the album is recorded and only the Apple Music
    /// write needs re-running.
    func add(storeId: String, writeOnly: Bool = false) async {
        await run(storeId, writeOnly: writeOnly)
    }

    func retry(storeId: String, writeOnly: Bool = false) async {
        await run(storeId, writeOnly: writeOnly)
    }

    /// "Add all (n)": one at a time — kinder to the Apple edge limiter (the feed measured 429
    /// bursts) and it keeps error-to-row attribution exact. Skips in-flight and owned items; an
    /// un-👍 while a row waits drops it.
    func addAll(_ storeIds: [String], writeOnly: Set<String> = []) async {
        guard !isAddingAll else { return }
        isAddingAll = true
        defer { isAddingAll = false; queued.subtract(storeIds) }
        queued.formUnion(storeIds.filter { !inFlight.contains($0) })
        for id in storeIds {
            guard queued.contains(id) else { continue }
            queued.remove(id)
            if inFlight.contains(id) || !stillAccepted(id) { continue }
            if let rel = store.releases[id], isOwned?(rel) == true, !writeOnly.contains(id) { continue }
            await run(id, writeOnly: writeOnly.contains(id))
        }
    }

    // MARK: the one add

    private func run(_ storeId: String, writeOnly: Bool) async {
        guard let rel = store.releases[storeId], !inFlight.contains(storeId) else {
            // A second request for an add already running is redundant — and must not leave the id
            // "queued", which would show the row busy forever.
            queued.remove(storeId)
            return
        }
        inFlight.insert(storeId)
        queued.remove(storeId)
        store.setAttempt(LikeAddAttempt(atMs: clock(), state: .adding, message: nil,
                                        writeToken: rel.attempt?.writeToken,
                                        recorded: rel.attempt?.recorded), for: storeId)
        let report = writeOnly ? await port.retryWrite(rel) : await port.add(rel)
        let now = clock()
        let outcome = Self.state(for: report, releaseAtMs: rel.releaseAtMs, nowMs: now,
                                 offline: port.isOffline)
        store.setAttempt(LikeAddAttempt(atMs: now, state: outcome.state, message: outcome.message,
                                        writeToken: report.write.storageToken,
                                        recorded: report.recorded), for: storeId)
        inFlight.remove(storeId)
    }

    // MARK: sweep + hydration

    /// Retry what can't have failed for a reason of his: `offline` items, and pre-orders whose
    /// release day has arrived. At most once per item per 6 h, sequentially, never `failed` items
    /// (those wait for his Retry tap), never an item he has since un-👍'd or now owns.
    @discardableResult
    func sweep(nowMs: Double? = nil) async -> Int {
        let now = nowMs ?? clock()
        let accepted = acceptedProvider?()
        if let accepted {
            // Prune rows whose verdict is gone. Never one that's mid-add.
            let keep = Set(accepted.keys.compactMap(LikedReleaseSelection.storeId(fromFeedbackId:)))
                .union(inFlight)
            store.prune(keepingAccepted: keep)
        }
        var ran = 0
        for rel in store.releases.values.sorted(by: { $0.storeId < $1.storeId }) {
            guard let a = rel.attempt, !inFlight.contains(rel.storeId), rel.tombstoned != true else { continue }
            let due: Bool
            switch a.state {
            case .offline: due = true
            case .awaitingRelease: due = (rel.releaseAtMs ?? .infinity) <= now
            default: due = false
            }
            guard due, now - a.atMs >= Self.sweepThrottleMs else { continue }
            if let accepted, accepted["rel:\(rel.storeId)"] == nil { continue }
            if isOwned?(rel) == true, a.state == .offline { continue }
            await run(rel.storeId, writeOnly: false)
            ran += 1
        }
        return ran
    }

    /// Fetch metadata for accepted `rel:` ids the cache has never seen (older likes, likes from
    /// another device, a lost cache) — in batches of 50, on the feed's own transport. Never called
    /// from a render path.
    @discardableResult
    func hydrateMissing(accepted: [String: Double]) async -> Int {
        guard let transport, transport.canSync else { return 0 }
        let missing = accepted.keys
            .compactMap(LikedReleaseSelection.storeId(fromFeedbackId:))
            .filter { store.releases[$0] == nil }
            .sorted()
        guard !missing.isEmpty else { return 0 }
        var got = 0
        var i = 0
        while i < missing.count {
            let batch = Array(missing[i..<min(i + Self.hydrateBatch, missing.count)])
            i += Self.hydrateBatch
            guard let found = await LikedReleaseHydration.fetch(
                ids: batch, transport: transport,
                likedAtMs: { accepted["rel:\($0)"] }) else { continue }
            store.upsert(found)
            got += found.count
        }
        return got
    }
}
