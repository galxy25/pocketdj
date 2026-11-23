import Foundation

// ============================================================================
// MARK: - Liked releases (For You ▸ New: a 👍 adds the record)
// ============================================================================
//
// WHY THIS FILE EXISTS. A 👍 on a New row used to be PURE FEEDBACK: it wrote a `rel:<albumId>`
// verdict, `offered()` then removed the release from both sections, and nothing was ever added —
// Levi, verbatim: "otherwise it's training the algo which is good but not building my
// collection". Two things follow and both live here, as PURE values so they are unit-testable
// without MusicKit, a network or a view:
//
//   1. what we remember about a liked release (`LikedRelease`) — the verdict log only stores an
//      id, and the feed cache keeps only each artist's LATEST release, so a liked record drops
//      out of the cache the moment its artist puts out something newer. Resurfacing needs its
//      own metadata.
//   2. which liked releases still need adding (`LikedReleaseSelection`) — "resurface any ones
//      previously liked but not added so I can actually add them".
//
// The verdict log (`RecFeedbackStore`) stays the synced source of truth for WHAT HE LIKED and
// `DiscoverAddsStore` for WHAT WAS ADDED. Nothing here is synced: it is a per-install cache that
// hydration can always rebuild from the verdict ids.
//
// Android has the same types in `data/recs/LikedReleases.kt`, with the same JSON shape and the
// same rules — keep them in step.

/// Where a like-add stands. A STRING on disk (the never-rename-a-shipped-rawValue rule).
enum LikeAddState: String, Codable, Equatable, Sendable {
    /// In flight. NEVER trusted across a launch: on load it becomes `.offline`, so a crash
    /// mid-add is retried by the sweep instead of spinning forever.
    case adding
    /// The album was recorded (and, where the platform can write, the Apple Music write proven).
    case added
    /// A real failure — waits for his Retry tap, never auto-retried.
    case failed
    /// Nothing recorded because the device couldn't reach anything. The sweep retries it.
    case offline
    /// A pre-order: tried now (Apple Music supports pre-adds), re-run on release day.
    case awaitingRelease
}

/// The last add attempt for one liked release.
struct LikeAddAttempt: Codable, Equatable, Sendable {
    var atMs: Double
    var state: LikeAddState
    /// The honest reason, in the same words the album page uses.
    var message: String?
    /// `AppleMusicLibraryWriteOutcome.storageToken` of the write, so "proven" survives a relaunch.
    var writeToken: String?
    /// Whether the provisional album was recorded — decides whether Retry re-runs the whole add
    /// or ONLY the Apple Music write (`retryAlbumLibraryWrite`).
    var recorded: Bool?

    var writeProven: Bool { AppleMusicLibraryWriteOutcome.provenByToken(writeToken) }
}

/// One release he 👍'd, as much as we need to show it and add it later.
///
/// Every field but `storeId` is optional on disk and a bad row is skipped rather than failing the
/// file — the `LenientDecision` / `ReleaseFeedService.Document` pattern.
struct LikedRelease: Codable, Equatable, Identifiable, Sendable {
    var storeId: String
    var artistId: Int?
    var artistName: String
    var title: String?
    var artworkUrl: String?
    var releaseAtMs: Double?
    /// "album" | "single" | "ep" | "compilation" — Apple's own wording, as the feed carries it.
    var kind: String?
    var trackCount: Int?
    var explicit: Bool?
    var likedAtMs: Double?
    var attempt: LikeAddAttempt?
    /// Apple didn't return this id from the catalog (pulled). Never asked about again.
    var tombstoned: Bool?

    var id: String { storeId }

    init(storeId: String, artistId: Int? = nil, artistName: String = "", title: String? = nil,
         artworkUrl: String? = nil, releaseAtMs: Double? = nil, kind: String? = nil,
         trackCount: Int? = nil, explicit: Bool? = nil, likedAtMs: Double? = nil,
         attempt: LikeAddAttempt? = nil, tombstoned: Bool? = nil) {
        self.storeId = storeId; self.artistId = artistId; self.artistName = artistName
        self.title = title; self.artworkUrl = artworkUrl; self.releaseAtMs = releaseAtMs
        self.kind = kind; self.trackCount = trackCount; self.explicit = explicit
        self.likedAtMs = likedAtMs; self.attempt = attempt; self.tombstoned = tombstoned
    }

    enum CodingKeys: String, CodingKey {
        case storeId, artistId, artistName, title, artworkUrl, releaseAtMs, kind, trackCount
        case explicit, likedAtMs, attempt, tombstoned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storeId = try c.decode(String.self, forKey: .storeId)
        artistId = try? c.decode(Int.self, forKey: .artistId)
        artistName = (try? c.decode(String.self, forKey: .artistName)) ?? ""
        title = try? c.decode(String.self, forKey: .title)
        artworkUrl = try? c.decode(String.self, forKey: .artworkUrl)
        releaseAtMs = try? c.decode(Double.self, forKey: .releaseAtMs)
        kind = try? c.decode(String.self, forKey: .kind)
        trackCount = try? c.decode(Int.self, forKey: .trackCount)
        explicit = try? c.decode(Bool.self, forKey: .explicit)
        likedAtMs = try? c.decode(Double.self, forKey: .likedAtMs)
        // An unknown `state` string fails the attempt only — the release itself survives.
        attempt = try? c.decode(LikeAddAttempt.self, forKey: .attempt)
        tombstoned = try? c.decode(Bool.self, forKey: .tombstoned)
    }

    /// Captured at like time from the feed row in hand — the common path, no network.
    /// Nil when the entry has no release id (a `relartist:` row can't be added).
    init?(entry e: ArtistReleaseEntry, likedAtMs: Double) {
        guard let id = e.releaseId else { return nil }
        self.init(storeId: id, artistId: e.artistId, artistName: e.artistName, title: e.releaseName,
                  artworkUrl: e.releaseArtworkUrl, releaseAtMs: e.releaseAtMs, kind: e.releaseKind,
                  trackCount: e.trackCount, explicit: e.explicit, likedAtMs: likedAtMs)
    }

    /// The identity the feed's ownership probes take — the SAME predicates, so "owned by any
    /// path" removes a liked row with no extra bookkeeping. Nil without an artist id (a hydrated
    /// row whose response carried no artist relationship): the id probe can still run, so we
    /// substitute 0, which no catalog artist has.
    var identity: ReleaseIdentity {
        ReleaseIdentity(storeId: storeId, artistId: artistId ?? 0, artistName: artistName, title: title)
    }

    /// The same value the album page is pushed with, so a Liked row opens `AlbumPreviewView`.
    var albumRef: AppleMusicAlbumRef {
        AppleMusicAlbumRef(storeID: storeId, title: title ?? "", artist: artistName, year: nil,
                           artworkURL: artworkUrl.flatMap { ArtworkTemplate.url($0, size: 160) },
                           url: URL(string: "https://music.apple.com/us/album/\(storeId)"))
    }

    /// Pre-release as of `nowMs`.
    func isUpcoming(nowMs: Double) -> Bool { (releaseAtMs ?? 0) > nowMs }
}

// ============================================================================
// MARK: - Selection (pure — the heart of "resurface what I liked but never added")
// ============================================================================

/// One row of the "Liked — not added" section.
struct LikedRow: Identifiable, Equatable {
    var release: LikedRelease
    /// When he gave the 👍 (the ordering key).
    var acceptedAtMs: Double
    /// An add is running for it right now (screen-independent, owned by `NewReleaseLikeAdder`).
    var inFlight: Bool
    /// The album IS recorded (owned) but the Apple Music write isn't proven → the row offers
    /// "Retry Apple Music", which re-runs only the write.
    var retryWriteOnly: Bool
    /// What the status line says; nil for a plain not-yet-added row.
    var message: String?

    var id: String { release.storeId }
    var state: LikeAddState? { release.attempt?.state }
}

enum LikedReleaseSelection {

    /// `added` stays hidden this long even if the ownership probes haven't caught up — the
    /// catalog rebuild and the CloudKit sync both lag a fresh add.
    static let addedGraceMs: Double = 24 * 3_600_000
    /// A proven pre-add comes back into Liked this long after release day if it still isn't
    /// owned — the sweep's release-day add evidently didn't land.
    static let preAddReturnMs: Double = 3 * 86_400_000

    /// `rel:<storeId>` → `<storeId>`; nil for `relartist:` (no release to add) and anything else.
    static func storeId(fromFeedbackId id: String) -> String? {
        guard id.hasPrefix("rel:") else { return nil }
        let s = String(id.dropFirst(4))
        return s.isEmpty ? nil : s
    }

    struct Result: Equatable {
        var rows: [LikedRow]
        /// Accepted `rel:` ids we hold no metadata for — older likes, likes from another device,
        /// a lost cache. Hydration fetches them; the render path never does.
        var needsHydration: [String]
    }

    /// - Parameters:
    ///   - accepted: `RecFeedbackStore.acceptedInScope("new")` — feedbackId → accepted-at ms.
    ///   - meta: `LikedReleasesStore` rows by storeId. Their `attempt` is the add history.
    ///   - owns / ownsVersion: the SAME probes `ReleaseFeedService.feed` applies.
    ///   - writeNeedsRetry: a note when the release's provisional album exists but its Apple
    ///     Music write isn't proven and this device can write (nil otherwise).
    ///   - inFlight: storeIds with an add running now.
    static func likedNotAdded(
        accepted: [String: Double],
        meta: [String: LikedRelease],
        owns: (ReleaseIdentity) -> Bool,
        ownsVersion: (Int, String, String) -> Bool,
        writeNeedsRetry: (String) -> String?,
        inFlight: Set<String>,
        nowMs: Double
    ) -> Result {
        var rows: [LikedRow] = []
        var hydrate: [String] = []
        for (feedbackId, at) in accepted {
            // 1. Only releases. A `relartist:` like is pure feedback — nothing to add.
            guard let sid = storeId(fromFeedbackId: feedbackId) else { continue }
            // 2. No metadata → can't render or add it yet. (A tombstoned id is never re-asked.)
            guard let rel = meta[sid] else { hydrate.append(sid); continue }
            if rel.tombstoned == true { continue }

            let working = inFlight.contains(sid)
            // 3. Owned by ANY path → gone, unless the Apple Music write is unproven.
            let owned = owns(rel.identity)
                || (rel.title.map { ownsVersion(rel.artistId ?? 0, rel.artistName, $0) } ?? false)
            if owned {
                if let note = writeNeedsRetry(sid) {
                    rows.append(LikedRow(release: rel, acceptedAtMs: at, inFlight: working,
                                         retryWriteOnly: true, message: note))
                }
                continue
            }
            if working {
                rows.append(LikedRow(release: rel, acceptedAtMs: at, inFlight: true,
                                     retryWriteOnly: false, message: nil))
                continue
            }
            if let a = rel.attempt {
                // 4. Just added: hide while the catalog / sync catch up.
                if a.state == .added, nowMs - a.atMs < addedGraceMs { continue }
                // 5. A proven pre-add lives in Coming soon ("Pre-added") until well past release.
                if a.state == .awaitingRelease, a.writeProven {
                    let returnAt = (rel.releaseAtMs ?? 0) + preAddReturnMs
                    if rel.releaseAtMs == nil || nowMs < returnAt { continue }
                }
            }
            // 6. No age limit: a like from six months ago that was never added still shows.
            rows.append(LikedRow(release: rel, acceptedAtMs: at, inFlight: false,
                                 retryWriteOnly: false, message: rel.attempt?.message))
        }
        // 7. In-flight and errors first, then most recently liked first.
        func urgent(_ r: LikedRow) -> Bool {
            if r.inFlight || r.retryWriteOnly { return true }
            switch r.state {
            case .adding?, .failed?, .offline?: return true
            default: return false
            }
        }
        rows.sort {
            let (a, b) = (urgent($0), urgent($1))
            if a != b { return a }
            if $0.acceptedAtMs != $1.acceptedAtMs { return $0.acceptedAtMs > $1.acceptedAtMs }
            return $0.id < $1.id
        }
        return Result(rows: rows, needsHydration: hydrate.sorted())
    }

    /// Accepted releases that are pre-added with a PROVEN write and not yet released — the set
    /// the Coming-soon section badges "Pre-added".
    static func preAdded(meta: [String: LikedRelease], nowMs: Double) -> Set<String> {
        Set(meta.values.compactMap { r in
            guard let a = r.attempt, a.state == .awaitingRelease, a.writeProven else { return nil }
            return r.storeId
        })
    }
}

// ============================================================================
// MARK: - Hydration decode: GET /v1/catalog/us/albums?ids=
// ============================================================================

/// The wire shape of the album lookup used to rebuild metadata for a liked id the cache has
/// never seen. Modelled as loosely as `ArtistsCatalogResponse`, for the same reason: a sparse
/// album must not throw the whole batch away.
struct AlbumsCatalogResponse: Decodable {
    struct Attributes: Decodable {
        let name: String?
        let artistName: String?
        let releaseDate: String?
        let artwork: ArtistsCatalogResponse.Artwork?
        let trackCount: Int?
        let contentRating: String?
        let isSingle: Bool?
        let isCompilation: Bool?
    }
    struct ArtistRef: Decodable { let id: String? }
    struct ArtistsRel: Decodable { let data: [ArtistRef]? }
    struct Relationships: Decodable { let artists: ArtistsRel? }
    struct Resource: Decodable {
        let id: String?
        let attributes: Attributes?
        let relationships: Relationships?
    }
    let data: [Resource]?

    /// Releases for the ids that came back, plus the ids Apple did NOT return (pulled from the
    /// catalog) as tombstones, so they are never asked about again.
    func releases(requested: [String], likedAtMs: (String) -> Double?) -> [LikedRelease] {
        var out: [LikedRelease] = []
        var seen = Set<String>()
        for r in data ?? [] {
            guard let id = r.id, !id.isEmpty else { continue }
            seen.insert(id)
            let a = r.attributes
            let kind: String? = {
                guard a != nil else { return nil }
                if a?.isSingle == true { return "single" }
                if a?.isCompilation == true { return "compilation" }
                return "album"
            }()
            out.append(LikedRelease(
                storeId: id,
                artistId: r.relationships?.artists?.data?.first?.id.flatMap(Int.init),
                artistName: a?.artistName ?? "",
                title: a?.name,
                artworkUrl: a?.artwork?.url,
                releaseAtMs: ArtistsCatalogResponse.parseReleaseDate(a?.releaseDate),
                kind: kind,
                trackCount: a?.trackCount,
                explicit: a?.contentRating.map { $0 == "explicit" },
                likedAtMs: likedAtMs(id)))
        }
        for id in requested where !seen.contains(id) {
            out.append(LikedRelease(storeId: id, likedAtMs: likedAtMs(id), tombstoned: true))
        }
        return out
    }
}

/// Batched album lookup on the transport the feed already uses (backoff included).
enum LikedReleaseHydration {
    /// ≤50 ids per request — the same hard cap the artists endpoint measured.
    static func request(ids: [String]) -> URLRequest? {
        var comps = URLComponents(string: "https://api.music.apple.com/v1/catalog/us/albums")!
        comps.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return req
    }

    /// nil on any failure (the ids simply stay un-hydrated and are asked about again later). A
    /// response whose `data` is absent is an error envelope, not "no albums" — treating it as
    /// all-tombstoned would permanently forget real likes.
    static func fetch(ids: [String], transport: ReleaseFeedTransport,
                      likedAtMs: @escaping (String) -> Double?,
                      sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
        async -> [LikedRelease]?
    {
        guard !ids.isEmpty else { return [] }
        guard let req = request(ids: ids) else { return nil }
        let maxAttempts = 4
        for attempt in 0..<maxAttempts {
            do {
                let data = try await transport.fetch(req)
                let decoded = try JSONDecoder().decode(AlbumsCatalogResponse.self, from: data)
                guard decoded.data != nil else { return nil }
                return decoded.releases(requested: ids, likedAtMs: likedAtMs)
            } catch {
                let retryable = (error as? ReleaseFeedTransportError)?.isRetryable ?? (error is URLError)
                guard retryable, attempt < maxAttempts - 1 else { return nil }
                let base = min(30, pow(2.0, Double(attempt + 1)))
                await sleep(base + Double.random(in: 0...(base / 2)))
            }
        }
        return nil
    }
}
