import Foundation

/// Thin async client for the PocketDJ recommendation engine (`Config.recEngineBase` — the
/// `pocketdj-rec-engine` Lambda behind API Gateway). Follows the `RipServerService` /
/// `JukeboxClient` shape: NOT `@MainActor`, short timeouts so an unreachable endpoint fails
/// fast, and an injectable transport closure so tests capture the exact `URLRequest`s.
///
/// Auth per call: `Authorization: Bearer <key>` (the per-profile random key
/// `RecommendationService` mints + syncs via CloudKit) plus the standard
/// `PDJIdentityHeaders` (`X-PocketDJ-Profile` / `X-PocketDJ-Device`).
///
/// The `profileId` passed in is the caller's business, and `RecommendationService` deliberately
/// does NOT pass the broadcast one: it derives `HMAC-SHA256(profileId, key: bearer)` so a
/// user-configured third-party server (jukebox broker, shared rip server) that logged the
/// broadcast `X-PocketDJ-Profile` can't address this profile's rec state. See that type's doc.
///
/// A 403 is not one condition — the body names it (`key-mismatch` vs `enrollment-required`)
/// and the recoveries differ, so `run` maps it to distinct `ClientError`s.
struct RecEngineClient {
    var base: URL = Config.recEngineBase
    /// The shared enrollment secret (`Config.recEngineEnrollSecret`) — see its doc: the server
    /// requires it to CREATE a profile's state and accepts it in place of a mismatched key on
    /// DELETE. Rides only the two routes that can create or destroy state; the read routes
    /// authenticate with the bearer key alone.
    var enrollSecret: String = Config.recEngineEnrollSecret
    var transport: (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    static let enrollHeader = "X-PocketDJ-Enroll"

    enum ClientError: Error, Equatable {
        case http(Int)
        case keyMismatch
        /// The server refused to CREATE state because the presented enrollment secret didn't
        /// match (`{ error: 'enrollment-required' }`) — the deployed secret was rotated and this
        /// build still carries the old constant. Distinct from `.keyMismatch` because the
        /// recoveries differ: a key mismatch is fixed in-app ("Delete cloud data"), a rotated
        /// secret only by updating the app.
        case enrollmentRequired
        case badResponse
    }

    private func request(_ path: String, method: String, key: String, profileId: String,
                         query: [URLQueryItem] = [], body: Data? = nil,
                         timeout: TimeInterval = 20, enroll: Bool = false) throws -> URLRequest {
        guard var comps = URLComponents(url: base.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw ClientError.badResponse
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw ClientError.badResponse }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if enroll, !enrollSecret.isEmpty {
            req.setValue(enrollSecret, forHTTPHeaderField: Self.enrollHeader)
        }
        PDJIdentityHeaders.apply(to: &req, profileId: profileId)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, resp) = try await transport(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw Self.map403(data) }
        guard (200..<300).contains(code) else { throw ClientError.http(code) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw ClientError.badResponse
        }
        return decoded
    }

    /// A 403's body names WHICH refusal this is (`enrollment-required` vs `key-mismatch` vs
    /// `profile-cap-reached`) and the recoveries differ, so the client must not collapse them.
    /// Anything unrecognized keeps the old `.keyMismatch` mapping — the in-app reset path is
    /// the only recovery the app can offer for an unknown refusal anyway.
    private static func map403(_ body: Data) -> ClientError {
        struct Err: Decodable { let error: String? }
        let kind = (try? JSONDecoder().decode(Err.self, from: body))?.error
        return kind == "enrollment-required" ? .enrollmentRequired : .keyMismatch
    }

    /// `POST /events` — upload a delta batch. Longer timeout: a first-enable drain can carry
    /// a full 2000-event batch. Carries the enrollment secret: the FIRST upload of a profile
    /// is what creates its server-side state, and the server refuses that without it.
    func postEvents(_ batch: RecUploadBatch, key: String, profileId: String) async throws -> RecUploadResponse {
        let body = try JSONEncoder().encode(batch)
        return try await run(
            try request("events", method: "POST", key: key, profileId: profileId,
                        body: body, timeout: 30, enroll: true),
            as: RecUploadResponse.self)
    }

    /// `GET /recs/songs?limit=N` — the For You list.
    func forYou(limit: Int, key: String, profileId: String) async throws -> RecSongsResponse {
        try await run(
            try request("recs/songs", method: "GET", key: key, profileId: profileId,
                        query: [URLQueryItem(name: "limit", value: String(limit))]),
            as: RecSongsResponse.self)
    }

    /// `GET /recs/collections?songId=S` — collection suggestions for one song.
    func collectionSuggestions(songId: String, key: String, profileId: String) async throws -> RecCollectionsResponse {
        try await run(
            try request("recs/collections", method: "GET", key: key, profileId: profileId,
                        query: [URLQueryItem(name: "songId", value: songId)]),
            as: RecCollectionsResponse.self)
    }

    /// `DELETE /state` — remove the profile's server-side state ("Delete cloud data").
    /// Carries the enrollment secret so a device whose key no longer matches the server's TOFU
    /// binding can still erase — that is the ONLY in-app recovery from a wedged key.
    func deleteState(key: String, profileId: String) async throws {
        struct Ack: Decodable { let deleted: Bool? }
        _ = try await run(
            try request("state", method: "DELETE", key: key, profileId: profileId, enroll: true),
            as: Ack.self)
    }

    /// `GET /health` — unauthenticated reachability probe.
    func health() async -> Bool {
        struct Health: Decodable { let ok: Bool? }
        var req = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 12)
        req.httpMethod = "GET"
        guard let (data, resp) = try? await transport(req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let h = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        return h.ok == true
    }
}
