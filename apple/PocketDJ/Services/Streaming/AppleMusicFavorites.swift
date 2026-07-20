import Foundation

/// Apple Music ♥ read/write — the ONE place that speaks the Apple Music Web API.
///
/// WHY THE WEB API AND NOT MusicKit. MusicKit has no favorites, loves, or ratings surface
/// at all: a grep of the iOS 26.5 and macOS `MusicKit.swiftinterface` files for
/// `favorite|love|Rating` returns only `ContentRating` (the explicit-content advisory).
/// The love state is reachable ONLY through `api.music.apple.com`, which MusicKit makes
/// painless via `MusicDataRequest` — it auto-attaches BOTH the developer token and the
/// Music-User-Token (`MusicDataRequest.tokenProvider`), so there is no JWT to sign, no
/// secret to ship, and no token to manage on device. `MusicDataRequest` is also available
/// on macOS (unlike `MusicLibrary`'s write methods), so this path works on every platform.
///
/// THE TWO ENDPOINTS ARE NOT THE SAME THING, and PocketDJ writes BOTH on favorite
/// (Levi 2026-07-20):
///
///   • `POST /v1/me/favorites?ids=…` — the ★ in the modern Music app; adds to the user's
///     "Favorite Songs" playlist. Query-param only, no body, 202 Accepted.
///     **Apple ships NO delete counterpart** — verified against the complete Apple Music
///     API symbol index. Favoriting through this endpoint is IRREVERSIBLE from any app.
///
///   • `PUT/DELETE /v1/me/ratings/songs/{id}` — the loved/disliked rating, `value: 1` or
///     `-1`. Fully reversible AND readable (`GET /v1/me/ratings/songs?ids=…`), so this is
///     the mechanism that makes genuine two-way sync possible.
///
/// The consequence, accepted deliberately: **un-favoriting is lossy.** It removes the
/// rating (so the app, and Apple's recommendations, agree) but cannot retract the ★ —
/// that entry stays in Apple Music's "Favorite Songs" until the user removes it there.
/// `unfavorite` therefore does exactly one thing, and the UI says so.
///
/// The ratings GET is also the INBOUND half: `lovedIds` reads back which of a batch of
/// catalog ids the account currently loves, which is what pulls Apple Music ♥ into the app.
enum AppleMusicFavorites {

    /// The catalog-song ratings resource. Library-song ratings live at
    /// `/v1/me/ratings/library-songs/{id}`; PocketDJ keys on CATALOG ids
    /// (`IndexSong.appleMusicId`, resolved by `scripts/resolve-apple-music-catalog.mjs`),
    /// so the catalog form is the correct one everywhere here.
    static let base = URL(string: "https://api.music.apple.com")!

    /// Apple caps a multi-id request; keep batches well under it. The ratings GET is the
    /// only call that batches, and the catalog is ~93k songs, so this bounds the pull to a
    /// few hundred requests rather than one impossible URL.
    static let batchSize = 250

    // MARK: - Request construction (pure — unit-tested without a network or an account)

    /// `PUT /v1/me/ratings/songs/{id}` with `{"type":"rating","attributes":{"value":1}}`.
    /// `value` is `1` (loved) or `-1` (disliked); PocketDJ only ever writes `1`.
    static func loveRequest(appleMusicId: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("/v1/me/ratings/songs/\(appleMusicId)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = #"{"type":"rating","attributes":{"value":1}}"#.data(using: .utf8)
        return req
    }

    /// `DELETE /v1/me/ratings/songs/{id}` — back to unrated. The ONLY reversible half of
    /// a favorite (the ★ cannot be retracted; see the type doc).
    static func unloveRequest(appleMusicId: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("/v1/me/ratings/songs/\(appleMusicId)"))
        req.httpMethod = "DELETE"
        return req
    }

    /// `POST /v1/me/favorites?ids[songs]=…` — the ★ / "Favorite Songs" half. Ids ride as a
    /// QUERY parameter (there is no request body), and unknown ids are silently ignored by
    /// Apple rather than failing the batch.
    ///
    /// THE PARAMETER IS TYPE-SCOPED — `ids[songs]`, not a bare `ids`. Apple documents the
    /// parameter as "the ids of the specific type" and, on the sibling add-to-library
    /// endpoint, spells it out: "To indicate the type of resource to add, follow the ids
    /// with one of the allowed values. Add multiple types in the same request." A bare
    /// `ids=` carries no type, so the request is accepted and silently does nothing —
    /// which is the worst possible failure for the half we can never retract or verify
    /// (there is no favorites GET to read back, and no un-favorite to undo a mistake).
    ///
    /// Chunked like the ratings read: this is a query parameter, and an unbounded id list
    /// would build a URL long enough to be rejected outright by the time a first sync
    /// drains a real backlog.
    static func starRequests(appleMusicIds: [String]) -> [URLRequest] {
        batches(appleMusicIds).compactMap { chunk in
            var comps = URLComponents(url: base.appendingPathComponent("/v1/me/favorites"),
                                      resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "ids[songs]", value: chunk.joined(separator: ","))]
            guard let url = comps?.url else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            return req
        }
    }

    /// `GET /v1/me/ratings/songs?ids=…` — the inbound read. Returns the request for one
    /// batch; callers chunk with `batchSize`.
    static func ratingsRequest(appleMusicIds: [String]) -> URLRequest? {
        guard !appleMusicIds.isEmpty else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("/v1/me/ratings/songs"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "ids", value: appleMusicIds.joined(separator: ","))]
        guard let url = comps?.url else { return nil }
        return URLRequest(url: url)
    }

    /// Parse a ratings response into the ids the account LOVES (`value == 1`). Ids absent
    /// from the payload are unrated, and `-1` is an explicit dislike — neither is a ♥, so
    /// both are simply excluded.
    ///
    /// RETURNS NIL — never an empty set — WHEN THE BODY CANNOT BE READ. This distinction is
    /// the single most dangerous thing in the favorites feature. "No loved ids" and "I could
    /// not tell you which ids are loved" are indistinguishable as an empty `Set`, and the
    /// caller reconciles by unfavoriting everything the response omits. So a 200 response
    /// carrying a truncated body, an HTML error page, or a schema change would silently
    /// tombstone the user's ENTIRE favorites library. An unreadable body must abort the
    /// reconcile, and that requires it to be representable.
    ///
    /// Row-level tolerance is preserved where it is safe: rows are decoded INDIVIDUALLY, so
    /// one malformed entry costs that one id rather than the whole 250-song batch. Only a
    /// top-level failure — the `data` array itself missing or unreadable — yields nil.
    static func lovedIds(fromRatingsPayload data: Data) -> Set<String>? {
        struct Row: Decodable {
            struct Attributes: Decodable { let value: Int? }
            let id: String?
            let attributes: Attributes?
        }
        // Decode the envelope as raw JSON values first so a single bad row can be dropped
        // without failing the array decode (a strongly-typed `[Row]` is all-or-nothing).
        struct Envelope: Decodable { let data: [FailableRow]? }
        struct FailableRow: Decodable {
            let row: Row?
            init(from decoder: any Decoder) throws {
                row = try? Row(from: decoder)
            }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let rows = envelope.data else { return nil }
        var loved = Set<String>()
        for entry in rows {
            if let id = entry.row?.id, entry.row?.attributes?.value == 1 { loved.insert(id) }
        }
        return loved
    }

    /// Split ids into `batchSize` chunks for the ratings GET.
    static func batches(_ ids: [String], size: Int = batchSize) -> [[String]] {
        guard size > 0, !ids.isEmpty else { return [] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0 ..< min($0 + size, ids.count)])
        }
    }
}

// MARK: - Transport

/// The network seam. The real implementation runs every request through
/// `MusicDataRequest` so MusicKit attaches the developer + user tokens; tests substitute a
/// stub and drive the whole sync service with no account, no entitlement, and no network.
@MainActor
protocol AppleMusicFavoritesTransport: AnyObject {
    /// True when the account can actually be written to right now (MusicKit authorized +
    /// the Apple Music integration enabled in this build).
    var canSync: Bool { get }
    /// Perform a request, returning the response body. Throws on transport failure or a
    /// non-2xx status, so callers can retry.
    func send(_ request: URLRequest) async throws -> Data
}

#if canImport(MusicKit)
import MusicKit

/// `MusicDataRequest`-backed transport — the production path.
///
/// Note `MusicDataRequest` carries no macOS-unavailable annotation (unlike
/// `MusicLibrary`'s write methods), so favorites sync works on the Mac build too.
@available(iOS 16.0, macOS 14.0, *)
@MainActor
final class MusicKitFavoritesTransport: AppleMusicFavoritesTransport {

    var canSync: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    func send(_ request: URLRequest) async throws -> Data {
        guard canSync else { throw StreamingError.notConfigured }
        // MusicDataRequest takes an arbitrary URLRequest — so PUT/POST/DELETE all work —
        // and injects Authorization + Music-User-Token itself.
        let response = try await MusicDataRequest(urlRequest: request).response()
        return response.data
    }
}
#endif
