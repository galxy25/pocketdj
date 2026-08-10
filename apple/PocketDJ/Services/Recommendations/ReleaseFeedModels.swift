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

    var id: Int { artistId }
}

/// The wire shape of the ONE endpoint this feature calls:
/// `GET /v1/catalog/us/artists?ids=<=50&views=latest-release,similar-artists`
///
/// Modelled loosely on purpose — every nested container is optional, because an artist with no
/// releases, no similar artists, or no artwork returns the view with an empty (or absent) `data`,
/// and a strict model would throw the whole batch away over one sparse artist.
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

    struct Views: Decodable {
        let latestRelease: LatestReleaseView?
        let similarArtists: SimilarArtistsView?
        enum CodingKeys: String, CodingKey {
            case latestRelease = "latest-release"
            case similarArtists = "similar-artists"
        }
    }

    struct ArtistResource: Decodable {
        let id: String?
        let attributes: ArtistAttributes?
        let views: Views?
    }

    let data: [ArtistResource]?
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

    /// Flatten one batch response into cache entries.
    func entries(checkedAtMs: Double) -> [ArtistReleaseEntry] {
        (data ?? []).compactMap { artist in
            guard let idStr = artist.id, let artistId = Int(idStr) else { return nil }
            let release = artist.views?.latestRelease?.data?.first
            let attrs = release?.attributes
            let kind: String? = {
                guard attrs != nil else { return nil }
                if attrs?.isSingle == true { return "single" }
                if attrs?.isCompilation == true { return "compilation" }
                return "album"
            }()
            let similar = (artist.views?.similarArtists?.data ?? []).compactMap { $0.id.flatMap(Int.init) }
            return ArtistReleaseEntry(
                artistId: artistId,
                artistName: artist.attributes?.name ?? "",
                checkedAtMs: checkedAtMs,
                releaseId: release?.id,
                releaseName: attrs?.name,
                releaseAtMs: Self.parseReleaseDate(attrs?.releaseDate),
                releaseArtworkUrl: attrs?.artwork?.url,
                releaseKind: kind,
                trackCount: attrs?.trackCount,
                explicit: attrs?.contentRating.map { $0 == "explicit" },
                similarArtistIds: similar.isEmpty ? nil : similar,
                similarCheckedAtMs: similar.isEmpty ? nil : checkedAtMs)
        }
    }
}
