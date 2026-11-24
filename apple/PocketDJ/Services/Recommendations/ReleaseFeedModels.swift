import Foundation

// ============================================================================
// MARK: - Policy (pure — unit-tested off the network)
// ============================================================================

/// When to re-ask Apple Music what an artist has released, and what counts as "new".
///
/// ── WHY A PER-ARTIST TTL AT ALL ──────────────────────────────────────────────────────────────
/// Apple exposes NO artist-popularity field, and the REST catalog API exposes no user play counts,
/// so there is no server-side signal for "which of these artists is worth re-checking often". The
/// only ranking that exists is the owner's OWN listening. An artist he plays constantly gets
/// checked every couple of days; one he played once last year gets checked twice a month.
///
/// ── WHY TTL_max IS 14 AND NOT 30 (load-bearing) ──────────────────────────────────────────────
/// The feed window is 30 days. If the coldest TTL equalled the window, an artist could release on
/// day 0, go unplayed, and then be played on day 29 with a cache entry that is still "fresh" —
/// the check would not fire, and by the time it did the release would have fallen out of the
/// window. That release would NEVER surface. Capping the TTL at 14 days guarantees at least one
/// check inside every 30-day window, so nothing can slip through the gap. Raising this constant to
/// 30 silently reintroduces that hole.
///
/// ── WHY THE DECAY IS A FRESHNESS KNOB, NOT A COST KNOB ───────────────────────────────────────
/// Steady state is roughly ONE batched request per day regardless of how the TTLs are tuned — the
/// batch endpoint takes 50 artists at a time and the check only fires on playback. Tightening the
/// decay buys fresher answers, not a smaller bill; it should not be sold as a saving.
enum ReleaseFeedPolicy {

    /// The feed window. A release is "new" if it landed within this many days.
    static let windowDays: Double = 30

    /// Ceiling on the release-check TTL. MUST stay strictly below `windowDays` — see the note
    /// above; this is the invariant that keeps a release from falling through the gap.
    static let maxReleaseTTLDays: Double = 14
    /// Floor on the release-check TTL: even the owner's most-played artist is not re-asked more
    /// than once every two days.
    static let minReleaseTTLDays: Double = 2

    /// Similar-artists staleness bounds. Similarity moves far more slowly than a release calendar,
    /// so it rides the same request but ages out ~4x slower.
    static let minSimilarTTLDays: Double = 30
    static let maxSimilarTTLDays: Double = 180

    /// Play count treated as "the top of the owner's library" when normalizing popularity. Taken
    /// from the observed maximum; a count above it simply saturates at pop = 1.
    static let referenceMaxPlays: Double = 2860

    /// How many artist ids the catalog endpoint accepts per request. Documented as 50 and MEASURED:
    /// 100 ids returns HTTP 400, so this is a hard cap, not a guideline.
    static let idsPerRequest = 50

    /// Concurrent in-flight requests. Deliberately tiny: the Apple edge limiter is bursty — a
    /// 40-way fan-out against this endpoint produced 24 separate HTTP 429s. Two at a time with
    /// backoff has been stable.
    static let maxConcurrentRequests = 2

    /// Normalized popularity in [0, 1], from the owner's own play count for the artist.
    /// Logarithmic because play counts are heavy-tailed — a linear scale would put all but a
    /// handful of artists at effectively zero and give them all the same TTL.
    static func popularity(plays: Int, reference: Double = referenceMaxPlays) -> Double {
        guard plays > 0 else { return 0 }
        let p = log2(1 + Double(plays)) / log2(1 + reference)
        return min(1, max(0, p))
    }

    /// Days before this artist's LATEST RELEASE should be re-fetched. This is the TTL that
    /// TRIGGERS network I/O.
    static func releaseTTLDays(plays: Int) -> Double {
        let pop = popularity(plays: plays)
        let raw = maxReleaseTTLDays * exp(-log(7.0) * pop)
        return min(maxReleaseTTLDays, max(minReleaseTTLDays, raw))
    }

    /// Days before this artist's SIMILAR-ARTISTS list is considered stale. Purely a LABEL: it
    /// never triggers a fetch of its own, so candidate generation stays free of network I/O and
    /// the similar list is simply refreshed whenever the release check happens to fire.
    static func similarTTLDays(plays: Int) -> Double {
        let raw = 4 * releaseTTLDays(plays: plays)
        return min(maxSimilarTTLDays, max(minSimilarTTLDays, raw))
    }

    /// Whether this artist is due a release check.
    static func isDue(lastCheckedAtMs: Double?, plays: Int, nowMs: Double) -> Bool {
        guard let last = lastCheckedAtMs else { return true }   // never checked
        let ageDays = (nowMs - last) / 86_400_000
        return ageDays >= releaseTTLDays(plays: plays)
    }

    /// Where a release sits relative to today. `nil` means it is not in the feed at all.
    ///
    /// ── WHY THE TWO STATES ARE NOT ONE LIST ──────────────────────────────────────────────────
    /// Apple returns pre-orders from `latest-release`, so the newest thing an artist has is
    /// routinely something that HAS NOT COME OUT YET. Those are the one class of item in the feed
    /// the owner cannot play, and presenting them beside things he can would make the screen lie:
    /// a record shipping in three weeks would read as "released today" under any age-in-days
    /// wording. They are worth showing — a pre-order is the freshest possible signal — but they
    /// have to be labelled as what they are.
    ///
    /// ── WHY COMING SOON HAS NO UPPER BOUND ───────────────────────────────────────────────────
    /// The 30-day window is a RECENCY filter: it exists to stop stale back-catalogue from
    /// crowding out new work. That reasoning does not run forwards. A pre-order announced 90 days
    /// out is still the artist's next release and nothing newer can displace it, so bounding the
    /// future side would mean the feed's freshest item is the one item it refuses to show.
    static func classify(releaseAtMs: Double, nowMs: Double) -> ReleaseStatus? {
        let ageDays = (nowMs - releaseAtMs) / 86_400_000
        if ageDays < 0 { return .comingSoon }
        return ageDays <= windowDays ? .outNow : nil
    }

    /// Whether a release date falls inside the feed at all — the union of both states.
    /// Defined in terms of `classify` so there is exactly ONE definition of the window and the
    /// two can never drift apart.
    static func isWithinWindow(releaseAtMs: Double, nowMs: Double) -> Bool {
        classify(releaseAtMs: releaseAtMs, nowMs: nowMs) != nil
    }
}

// ============================================================================
// MARK: - The one-shot seed set (pure)
// ============================================================================

/// WHICH ARTISTS THE FEED IS FIRST POPULATED FROM.
///
/// Pure over a play-event snapshot so it runs off the main actor and is unit-testable with an
/// injected clock — no store, no catalog, no network.
enum ReleaseFeedSeed {

    /// Distinct artist names played inside the window, MOST RECENTLY PLAYED FIRST.
    ///
    /// ── WHY `PlayHistoryStore` EVENTS AND NOT Library.xml ────────────────────────────────────
    /// Library.xml keeps only the LAST play per track, which erases exactly the repeat listening a
    /// 30-day window is made of: a record played every day for a month appears once, and an artist
    /// whose only recent play was a re-listen of an old track disappears entirely. The append-only
    /// event log has every play, which is what "the last 30 days of my listening" actually means.
    ///
    /// Ordering is deliberate: the batches go out 50 ids at a time, so if the set is ever large
    /// enough to matter the FRESHEST artists are checked first.
    static func recentArtistNames(_ events: [PlayHistoryStore.PlayEvent],
                                  nowMs: Double,
                                  days: Double = ReleaseFeedPolicy.windowDays,
                                  limit: Int = 2000) -> [String] {
        let cutoff = nowMs - days * 86_400_000
        var latest: [String: Double] = [:]     // folded name key → most recent play
        var display: [String: String] = [:]    // key → the name as recorded
        for e in events where e.playedAt >= cutoff {
            guard let raw = e.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
            else { continue }
            let key = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let at = latest[key], at >= e.playedAt { continue }
            latest[key] = e.playedAt
            display[key] = raw
        }
        return latest.sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { display[$0.key] }
    }
}

/// Out now, or still ahead. Kept as a first-class value rather than a `Bool isFuture` so the
/// sectioning, the tile copy, and the tests all agree on the same two names.
enum ReleaseStatus: String, Codable, Equatable, CaseIterable {
    /// Released on or before today, no more than `windowDays` ago — playable now.
    case outNow
    /// Future-dated. Apple returns pre-orders here; it cannot be played yet.
    case comingSoon

    var title: String {
        switch self {
        case .outNow: return "Out now"
        case .comingSoon: return "Coming soon"
        }
    }
}

// ============================================================================
// MARK: - Cache records (per-install, PERSONAL — never the shared index)
// ============================================================================

/// One artist's cached release answer. This lives in Application Support, NOT in the catalog
/// index: it is derived from the owner's play history and is his alone.
struct ArtistReleaseEntry: Codable, Equatable, Identifiable {
    /// Apple Music catalog artist id.
    var artistId: Int
    var artistName: String
    /// Epoch ms of the last successful release check — the TTL clock.
    var checkedAtMs: Double
    /// Latest release, when the artist has one at all.
    var releaseId: String?
    var releaseName: String?
    /// Epoch ms of the release date. Nil when Apple returned no parsable date.
    var releaseAtMs: Double?
    var releaseArtworkUrl: String?
    /// "album" | "single" | "ep" — Apple's own wording, passed through for the tile subtitle.
    var releaseKind: String?
    /// Track count, when the view returned one.
    var trackCount: Int?
    /// Whether the latest release carries an explicit advisory. Apple returns `contentRating` on
    /// this endpoint UNFILTERED — the explicit-search trap does not apply here.
    var explicit: Bool?
    /// Similar-artist catalog ids from the same request. Refreshed opportunistically; staleness is
    /// only a label (see `ReleaseFeedPolicy.similarTTLDays`).
    var similarArtistIds: [Int]?
    var similarCheckedAtMs: Double?
    /// Apple's CREDIT for this release ("Future, Drake & Metro Boomin"), which can name several
    /// artists. ADDITIVE-OPTIONAL: nil on rows written before the feed kept every release.
    /// Feeds the appears-on filter and the cross-artist id dedupe (`ReleaseFeedDedupe`).
    var releaseArtistName: String?

    var id: Int { artistId }
}

/// The wire shape of the feed's ONE batch request (design: docs/design/new-feed-all-releases.md):
/// ```
/// GET /v1/catalog/us/artists?ids=<=50&include=albums&limit[albums]=25&sort[albums]=-releaseDate
///     &fields[artists]=name&fields[albums]=name,releaseDate,artwork,trackCount,contentRating,
///      isSingle,isCompilation,artistName
/// ```
/// `relationships.albums` is each artist's release list, newest first. The decoder ALSO reads
/// `views.latest-release` / `views.similar-artists` when present (fixtures, old captured bodies):
/// releases are the union of both, deduped by id.
///
/// Modelled loosely on purpose — every nested container is optional, because an artist with no
/// releases or no artwork returns the container with an empty (or absent) `data`, and a strict
/// model would throw the whole batch away over one sparse artist.
struct ArtistsCatalogResponse: Decodable {
    struct Artwork: Decodable { let url: String? }

    struct ReleaseAttributes: Decodable {
        let name: String?
        let releaseDate: String?      // "2026-08-01" or "2026" — both occur
        let artwork: Artwork?
        let trackCount: Int?
        let contentRating: String?    // "explicit" | "clean" | absent
        let isSingle: Bool?
        let isCompilation: Bool?
        /// The release's credit line (may name several artists).
        let artistName: String?
    }

    struct ArtistAttributes: Decodable { let name: String? }

    struct ReleaseResource: Decodable {
        let id: String?
        let attributes: ReleaseAttributes?
    }

    struct SimilarResource: Decodable {
        let id: String?
        let attributes: ArtistAttributes?
    }

    struct LatestReleaseView: Decodable { let data: [ReleaseResource]? }
    struct SimilarArtistsView: Decodable { let data: [SimilarResource]? }
    struct AlbumsRelationship: Decodable {
        let data: [ReleaseResource]?
        let next: String?
    }

    struct Views: Decodable {
        let latestRelease: LatestReleaseView?
        let similarArtists: SimilarArtistsView?
        enum CodingKeys: String, CodingKey {
            case latestRelease = "latest-release"
            case similarArtists = "similar-artists"
        }
    }

    struct Relationships: Decodable { let albums: AlbumsRelationship? }

    struct ArtistResource: Decodable {
        let id: String?
        let attributes: ArtistAttributes?
        let views: Views?
        let relationships: Relationships?
    }

    let data: [ArtistResource]?
}

/// A page of `/artists/{id}/albums` — the rare overflow follow-up.
struct ArtistAlbumsPage: Decodable {
    let data: [ArtistsCatalogResponse.ReleaseResource]?
}

// ============================================================================
// MARK: - Per-artist release list (pure)
// ============================================================================

/// The cache's invariants for ONE artist's rows, enforced in one place.
enum ReleaseFeedCache {
    /// Rows beyond the head are kept this far back (the 30-day window plus a day of slack).
    static let keepDays: Double = ReleaseFeedPolicy.windowDays + 1
    /// Head plus this many more.
    static let maxExtraRows = 125

    /// Normalize one artist's rows. `rows[0]` is the SOURCE of the artist-level fields
    /// (name, check clock, similar data), which are then made identical on every row.
    ///
    /// Newest first (undated last); one row per release id; bare (release-less) rows only when
    /// there is nothing else; the head is always kept (that is exactly what the old one-entry
    /// cache stored), the rest only if future-dated or within `keepDays`; capped.
    static func normalize(rows: [ArtistReleaseEntry], nowMs: Double) -> [ArtistReleaseEntry] {
        guard let meta = rows.first else { return [] }
        var seen = Set<String>()
        var real: [ArtistReleaseEntry] = []
        for r in rows {
            guard let id = r.releaseId else { continue }
            if seen.insert(id).inserted { real.append(r) }
        }
        func apply(_ r: ArtistReleaseEntry) -> ArtistReleaseEntry {
            var r = r
            r.artistId = meta.artistId
            r.artistName = meta.artistName
            r.checkedAtMs = meta.checkedAtMs
            r.similarArtistIds = meta.similarArtistIds
            r.similarCheckedAtMs = meta.similarCheckedAtMs
            return r
        }
        guard !real.isEmpty else {
            var bare = meta
            bare.releaseId = nil; bare.releaseName = nil; bare.releaseAtMs = nil
            bare.releaseArtworkUrl = nil; bare.releaseKind = nil; bare.trackCount = nil
            bare.explicit = nil; bare.releaseArtistName = nil
            return [bare]
        }
        // Stable sort: newest first, undated last.
        let sorted = real.enumerated().sorted { a, b in
            let x = a.element.releaseAtMs ?? -Double.infinity
            let y = b.element.releaseAtMs ?? -Double.infinity
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        let cutoff = nowMs - keepDays * 86_400_000
        var out = [apply(sorted[0])]
        for r in sorted.dropFirst() {
            guard let at = r.releaseAtMs, at > nowMs || at >= cutoff else { continue }
            out.append(apply(r))
            if out.count >= 1 + maxExtraRows { break }
        }
        return out
    }

    /// Group a flat row list by artist, FIRST APPEARANCE order (so a file written head-first keeps
    /// its heads), without altering any row.
    static func group(_ rows: [ArtistReleaseEntry]) -> [Int: [ArtistReleaseEntry]] {
        var out: [Int: [ArtistReleaseEntry]] = [:]
        for r in rows { out[r.artistId, default: []].append(r) }
        return out
    }
}

// ============================================================================
// MARK: - Dedupe (pure)
// ============================================================================

/// One displayed record: the representative row and the rows it absorbed.
struct ReleaseGroup: Equatable {
    var rep: ArtistReleaseEntry
    var alternates: [ArtistReleaseEntry]
    var members: [ArtistReleaseEntry] { [rep] + alternates }
}

enum ReleaseFeedDedupe {

    /// Appears-on filter (apply time): keep a release only if the artist is in its credit. An
    /// empty or missing credit fails open.
    static func ownReleases(_ rows: [ArtistReleaseEntry], artistName: String) -> [ArtistReleaseEntry] {
        let me = RecVersionIdentity.artistKey(artistName)
        guard !me.isEmpty else { return rows }
        return rows.filter { r in
            guard let credit = r.releaseArtistName,
                  !credit.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
            let keys = RecVersionIdentity.creditArtistKeys(credit)
            return keys.isEmpty || keys.contains(me)
        }
    }

    /// One row per release id ACROSS artists: prefer the artist credited first, then the lower id.
    static func acrossArtists(_ rows: [ArtistReleaseEntry]) -> [ArtistReleaseEntry] {
        func position(_ r: ArtistReleaseEntry) -> Int {
            guard let credit = r.releaseArtistName else { return Int.max }
            let keys = RecVersionIdentity.creditArtistKeys(credit)
            return keys.firstIndex(of: RecVersionIdentity.artistKey(r.artistName)) ?? Int.max
        }
        var best: [String: ArtistReleaseEntry] = [:]
        var order: [String] = []
        for r in rows {
            guard let id = r.releaseId else { continue }
            if let cur = best[id] {
                let (pa, pb) = (position(r), position(cur))
                if pa < pb || (pa == pb && r.artistId < cur.artistId) { best[id] = r }
            } else { best[id] = r; order.append(id) }
        }
        return order.compactMap { best[$0] }
    }

    /// The title with " - Single" / " - EP" removed and version material parsed away.
    static func baseTitle(_ name: String) -> String? {
        let parsed = RecVersionIdentity.parse(stripKindSuffix(name))
        return parsed.base.isEmpty ? nil : parsed.base
    }

    /// Collapse editions and clean/explicit twins (read time). Group = (artist, album-or-single
    /// bucket, base title); collapsed only when every member parses `.standard` or `.cosmetic`.
    static func collapse(_ rows: [ArtistReleaseEntry],
                         hasVerdict: ((String) -> Bool)?,
                         prefersExplicit: (() -> Bool)?) -> [ReleaseGroup] {
        struct Key: Hashable { let artist: Int; let albumBucket: Bool; let base: String }
        var buckets: [Key: [ArtistReleaseEntry]] = [:]
        var slots: [(Key?, ArtistReleaseEntry?)] = []
        for r in rows {
            guard let name = r.releaseName, let base = baseTitle(name) else {
                slots.append((nil, r)); continue
            }
            let k = Key(artist: r.artistId, albumBucket: r.kindClass.isAlbumBucket, base: base)
            if buckets[k] == nil { slots.append((k, nil)) }
            buckets[k, default: []].append(r)
        }
        let preferExplicit = prefersExplicit?() ?? false
        var out: [ReleaseGroup] = []
        for (k, row) in slots {
            if let row { out.append(ReleaseGroup(rep: row, alternates: [])); continue }
            guard let k, let members = buckets[k] else { continue }
            let collapsible = members.count > 1 && members.allSatisfy {
                let klass = RecVersionIdentity.parse(Self.stripKindSuffix($0.releaseName ?? "")).klass
                return klass == .standard || klass == .cosmetic
            }
            guard collapsible else {
                out.append(contentsOf: members.map { ReleaseGroup(rep: $0, alternates: []) })
                continue
            }
            let verdict: (ArtistReleaseEntry) -> Bool = { r in
                r.releaseId.map { hasVerdict?("rel:\($0)") ?? false } ?? false
            }
            let sorted = members.sorted { a, b in
                let (va, vb) = (verdict(a), verdict(b))
                if va != vb { return va }
                let (ea, eb) = (a.explicit == true, b.explicit == true)
                if ea != eb { return ea == preferExplicit }
                let (ta, tb) = (a.releaseAtMs ?? -Double.infinity, b.releaseAtMs ?? -Double.infinity)
                if ta != tb { return ta > tb }
                return idLess(a.releaseId, b.releaseId)
            }
            out.append(ReleaseGroup(rep: sorted[0], alternates: Array(sorted.dropFirst())))
        }
        return out
    }

    private static func stripKindSuffix(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - single", " – single", " - ep", " – ep"] where n.lowercased().hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count)); break
        }
        return n
    }

    private static func idLess(_ a: String?, _ b: String?) -> Bool {
        switch (a.flatMap(Int.init), b.flatMap(Int.init)) {
        case let (x?, y?): return x < y
        default: return (a ?? "") < (b ?? "")
        }
    }
}

extension ArtistsCatalogResponse {
    /// Apple returns either a full date or a bare year. A bare year is NOT usable as a release
    /// timestamp for a 30-day window — parsing "2026" as 2026-01-01 would make every January
    /// release look months old and every other one look absent — so it decodes to nil and the
    /// entry simply carries no date.
    static func parseReleaseDate(_ raw: String?) -> Double? {
        guard let raw, raw.count >= 10 else { return nil }
        var c = DateComponents()
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal.date(from: c).map { $0.timeIntervalSince1970 * 1000 }
    }

    /// The artist ids whose relationship came back FULL (`limit`), still holding an in-window
    /// release at the oldest end, with a `next` page — the rare overflow follow-up candidates.
    func saturatedArtistIds(limit: Int, nowMs: Double) -> [Int] {
        (data ?? []).compactMap { artist in
            guard let id = artist.id.flatMap(Int.init),
                  let rel = artist.relationships?.albums, rel.next != nil,
                  let rows = rel.data, rows.count >= limit else { return nil }
            let oldest = rows.compactMap { Self.parseReleaseDate($0.attributes?.releaseDate) }.min()
            guard let oldest, ReleaseFeedPolicy.isWithinWindow(releaseAtMs: oldest, nowMs: nowMs)
            else { return nil }
            return id
        }
    }

    /// Map one wire release to a cache row (artist-level fields filled by the caller).
    static func row(_ release: ReleaseResource, artistId: Int, artistName: String,
                    checkedAtMs: Double) -> ArtistReleaseEntry {
        let attrs = release.attributes
        let kind: String? = {
            guard attrs != nil else { return nil }
            if attrs?.isSingle == true { return "single" }
            if attrs?.isCompilation == true { return "compilation" }
            return "album"
        }()
        return ArtistReleaseEntry(
            artistId: artistId, artistName: artistName, checkedAtMs: checkedAtMs,
            releaseId: release.id, releaseName: attrs?.name,
            releaseAtMs: parseReleaseDate(attrs?.releaseDate),
            releaseArtworkUrl: attrs?.artwork?.url, releaseKind: kind,
            trackCount: attrs?.trackCount,
            explicit: attrs?.contentRating.map { $0 == "explicit" },
            releaseArtistName: attrs?.artistName)
    }

    /// Flatten one batch response into cache ROWS: every release of every artist, grouped by
    /// artist, newest first as Apple returned them (union of `relationships.albums` and
    /// `views.latest-release`, deduped by id). An artist with nothing yields ONE bare row.
    func entries(checkedAtMs: Double) -> [ArtistReleaseEntry] {
        (data ?? []).flatMap { artist -> [ArtistReleaseEntry] in
            guard let idStr = artist.id, let artistId = Int(idStr) else { return [] }
            let name = artist.attributes?.name ?? ""
            let similar = (artist.views?.similarArtists?.data ?? []).compactMap { $0.id.flatMap(Int.init) }
            let releases = (artist.relationships?.albums?.data ?? [])
                + (artist.views?.latestRelease?.data ?? [])
            var seen = Set<String>()
            var rows: [ArtistReleaseEntry] = []
            for r in releases {
                guard let rid = r.id, seen.insert(rid).inserted else { continue }
                rows.append(Self.row(r, artistId: artistId, artistName: name, checkedAtMs: checkedAtMs))
            }
            if rows.isEmpty {
                rows = [ArtistReleaseEntry(artistId: artistId, artistName: name, checkedAtMs: checkedAtMs)]
            }
            rows[0].similarArtistIds = similar.isEmpty ? nil : similar
            rows[0].similarCheckedAtMs = similar.isEmpty ? nil : checkedAtMs
            return rows
        }
    }
}
