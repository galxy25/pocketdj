import Foundation
import Observation

/// The OWNER-ONLY bridge between `FavoritesStore` (local ♥, every profile) and Apple Music
/// (`AppleMusicFavorites`). Three jobs, in priority order:
///
///   1. **Gate.** Resolve `OwnerIdentity.isOwner()` once per launch and cache it. Not the
///      owner ⇒ this service does nothing at all: no push, no pull, no seed export. A
///      tester's ♥ stay in their own profile (their private CloudKit DB) exactly as asked.
///   2. **Push (outbound).** Drain `FavoritesStore.pendingPushes` — favorite writes BOTH
///      the ★ and the love rating; unfavorite deletes the rating (the ★ is not retractable;
///      see `AppleMusicFavorites`). Failures stay pending and retry, so an offline toggle
///      lands on the next pass rather than being lost.
///   3. **Pull (inbound).** Read back which catalog ids the account loves and fold them in
///      through `applyRemote`, which lets a NEWER local edit win. This is what makes a ♥
///      made in the Music app show up in PocketDJ.
///
/// SEEDING (non-owner path). A tester's first run fetches the shipped snapshot of the
/// owner's Apple Music favorites and applies it as their initial state — once, and never
/// over anything they've explicitly touched. That is the ONLY thing this service does for
/// a non-owner, and it is a pure download: nothing about a tester ever leaves their device.
///
/// CONCURRENCY: one pass at a time (`isSyncing`), so a foreground trigger landing on top of
/// a launch pass can't double-write. Every pass is best-effort — a thrown error ends the
/// pass and leaves the work pending for the next one.
@MainActor
@Observable
final class FavoritesSyncService {

    /// Resolved owner state: nil until the first gate check completes. Surfaced so
    /// Settings can explain WHY Apple Music sync is or isn't running.
    private(set) var isOwner: Bool?
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastSyncedAtMs: Double?

    @ObservationIgnored private let favorites: FavoritesStore
    @ObservationIgnored private let transport: (any AppleMusicFavoritesTransport)?
    /// Resolves catalog id → songId for the INBOUND direction: Apple Music speaks Apple
    /// Music ids, the app speaks PocketDJ song ids. Supplied by the app from the loaded
    /// catalog (`AppModel`), so this service stays free of the data layer.
    @ObservationIgnored var songIdForAppleMusicId: ((String) -> String?)?
    /// Every (songId, appleMusicId) pair in the catalog — the id space the inbound pull
    /// asks Apple Music about. Also supplied by the app.
    @ObservationIgnored var catalogAppleMusicIds: (() -> [(songId: String, appleMusicId: String)])?
    /// Overridable gate, so tests can drive both branches without CloudKit.
    @ObservationIgnored var ownerCheck: () async -> Bool = { await OwnerIdentity.isOwner() }
    /// Per-install USER OPT-IN for two-way sync (Settings ▸ Apple Music ▸ Favorites toggle) —
    /// the parity fix: the write path uses the user's OWN Music-User-Token against their OWN
    /// account, so anyone may enable it; the owner allowlist stays only as an always-on grant
    /// (and the seed-export gate). Wired in PocketDJApp to `settings.favoritesTwoWaySync`.
    @ObservationIgnored var userOptIn: () -> Bool = { false }

    /// Whether two-way sync is EFFECTIVELY on for this install (owner grant or user opt-in).
    var isTwoWayEnabled: Bool { isOwner == true || userOptIn() }
    /// Seed fetcher — overridable in tests. Returns the raw seed document bytes.
    @ObservationIgnored var fetchSeed: () async throws -> Data = {
        try await URLSession.shared.data(from: Config.favoritesSeedURL).0
    }

    init(favorites: FavoritesStore, transport: (any AppleMusicFavoritesTransport)?) {
        self.favorites = favorites
        self.transport = transport
    }

    /// The seed document shipped at `Config.favoritesSeedURL`.
    struct Seed: Codable {
        var version: Int
        /// PocketDJ song ids. Apple-Music-sourced only, by construction of the export.
        var songIds: [String]
        /// songId → Apple Music catalog id, so a seeded ♥ is pushable if the tester later
        /// becomes an owner. Optional — the seed is still valid without it.
        var appleMusicIds: [String: String]?
    }

    // MARK: - Entry points

    /// Called at launch and on foreground. Resolves the gate, then runs the owner sync or
    /// the tester seed. Never throws — failures land in `lastError`.
    func run() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        if isOwner == nil { isOwner = await ownerCheck() }

        do {
            if isTwoWayEnabled {
                // Owner grant OR the user's own opt-in — either way the push/pull writes only
                // to the REQUESTING user's account with their own Music-User-Token.
                try await push()
                try await pull()
                lastSyncedAtMs = Date().timeIntervalSince1970 * 1000
            } else {
                await applySeedIfNeeded()
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Push a single change immediately (the ♥ tap path), so a favorite reaches Apple
    /// Music now rather than at the next pass. Silently no-ops for a non-owner, for a song
    /// with no Apple Music identity (vinyl / My Digital / Studio), or when the account
    /// isn't currently writable — the entry simply stays pending.
    func pushNow(_ entry: FavoritesStore.Entry) async {
        guard isTwoWayEnabled, entry.appleMusicId != nil else { return }
        do { try await push(only: entry) } catch { lastError = String(describing: error) }
    }

    // MARK: - Outbound

    private func push(only single: FavoritesStore.Entry? = nil) async throws {
        guard let transport, transport.canSync else { return }
        let pending = single.map { [$0] } ?? favorites.pendingPushes
        guard !pending.isEmpty else { return }

        // ★ the newly-favorited in batched calls (the endpoint takes many ids and has no
        // per-id error), then the per-song reversible rating.
        let starIds = pending.filter(\.favorited).compactMap(\.appleMusicId)
        for starReq in AppleMusicFavorites.starRequests(appleMusicIds: starIds) {
            // Best-effort: the ★ is cosmetic next to the rating, and it is the half we can
            // never undo — a failure here must not block or un-mark the rating write.
            _ = try? await transport.send(starReq)
        }

        for entry in pending {
            guard let amId = entry.appleMusicId else { continue }
            let req = entry.favorited
                ? AppleMusicFavorites.loveRequest(appleMusicId: amId)
                : AppleMusicFavorites.unloveRequest(appleMusicId: amId)
            // A failed write leaves the entry pending (no markPushed) so the next pass retries.
            _ = try await transport.send(req)
            // Mark clean against the timestamp of the state we ACTUALLY sent, not the wall
            // clock on completion. If the user re-toggled while this request was in flight,
            // their newer edit has a later `atMs` and must stay pending — a fresh clock
            // reading would be newer than that edit and would mark it clean, discarding a
            // change that was never transmitted.
            favorites.markPushed(songId: entry.songId, pushedAtMs: entry.atMs)
        }
    }

    // MARK: - Inbound

    /// Read the account's loved songs and fold them into the store. Scoped to the ids the
    /// catalog actually knows: Apple Music may love songs PocketDJ has never indexed, and
    /// those have no song id to attach a ♥ to.
    private func pull() async throws {
        guard let transport, transport.canSync, let pairs = catalogAppleMusicIds?() else { return }
        guard !pairs.isEmpty else { return }

        let now = Date().timeIntervalSince1970 * 1000
        var loved = Set<String>()
        for batch in AppleMusicFavorites.batches(pairs.map(\.appleMusicId)) {
            guard let req = AppleMusicFavorites.ratingsRequest(appleMusicIds: batch) else { continue }
            // A partial read looks IDENTICAL to "these songs are no longer loved", so any
            // batch we cannot fully trust must abort the whole reconcile rather than
            // contribute an under-populated set. Two distinct failure modes, both fatal to
            // this pass: the transport throwing (propagates out of `pull`), and a 2xx whose
            // body doesn't parse — which `lovedIds` reports as nil precisely so it cannot
            // masquerade as an empty result and tombstone the user's entire library.
            let data = try await transport.send(req)
            guard let batchLoved = AppleMusicFavorites.lovedIds(fromRatingsPayload: data) else {
                throw StreamingError.notConfigured
            }
            loved.formUnion(batchLoved)
        }

        // Coalesced: the reconcile touches up to every catalog song, and an un-batched
        // `applyRemote` rewrites the entire favorites document each time — n atomic writes
        // and O(n²) encoding, synchronously on the main actor. One write at the end instead.
        favorites.withCoalescedSaves {
            for (songId, amId) in pairs {
                let isLoved = loved.contains(amId)
                // Only ADOPT upstream state; `applyRemote` itself protects newer local edits.
                // A song neither loved upstream nor touched locally is left untouched rather
                // than tombstoned — absence of a rating is not a decision to unfavorite.
                if isLoved || favorites.entry(songId) != nil {
                    favorites.applyRemote(songId: songId, favorited: isLoved,
                                          appleMusicId: amId, observedAtMs: now)
                }
            }
        }
    }

    // MARK: - Seeding (non-owner)

    private func applySeedIfNeeded() async {
        guard let data = try? await fetchSeed(),
              let seed = try? JSONDecoder().decode(Seed.self, from: data),
              seed.version > favorites.seedVersion else { return }
        favorites.applySeed(songIds: seed.songIds,
                            appleMusicIds: seed.appleMusicIds ?? [:],
                            version: seed.version)
    }

    /// The owner-only export that PRODUCES `favorites-seed.json`: the owner's
    /// APPLE-MUSIC-sourced favorites only. Vinyl / My Digital / Studio ♥ are personal and
    /// are excluded here by construction — that exclusion is the whole point of this
    /// function, so it filters on the presence of an Apple Music id rather than trusting
    /// the caller to pre-filter.
    func exportSeed(version: Int) -> Seed {
        let shareable = favorites.byId.values.filter { $0.favorited && $0.appleMusicId != nil }
        return Seed(version: version,
                    songIds: shareable.map(\.songId).sorted(),
                    appleMusicIds: Dictionary(uniqueKeysWithValues:
                        shareable.compactMap { e in e.appleMusicId.map { (e.songId, $0) } }))
    }
}
