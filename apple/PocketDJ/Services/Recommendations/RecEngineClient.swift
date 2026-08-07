import Foundation

/// Thin async client for the PocketDJ recommendation engine (`Config.recEngineBase` — the
/// `pocketdj-rec-engine` Lambda behind API Gateway). Follows the `RipServerService` /
/// `JukeboxClient` shape: NOT `@MainActor`, short timeouts so an unreachable endpoint fails
/// fast, and an injectable transport closure so tests capture the exact `URLRequest`s.
///
/// Auth per call: `Authorization: Bearer <key>` (the per-profile random key
/// `RecommendationService` mints + syncs via CloudKit) plus the standard
/// `PDJIdentityHeaders` (`X-PocketDJ-Profile` / `X-PocketDJ-Device`). A 403 means the
/// server's TOFU-bound key hash doesn't match this key → `.keyMismatch`.
struct RecEngineClient {
    var base: URL = Config.recEngineBase
    var transport: (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    enum ClientError: Error, Equatable {
        case http(Int)
        case keyMismatch
        case badResponse
    }

    private func request(_ path: String, method: String, key: String, profileId: String,
                         query: [URLQueryItem] = [], body: Data? = nil,
                         timeout: TimeInterval = 20) throws -> URLRequest {
        guard var comps = URLComponents(url: base.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw ClientError.badResponse
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw ClientError.badResponse }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
        if code == 403 { throw ClientError.keyMismatch }
        guard (200..<300).contains(code) else { throw ClientError.http(code) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw ClientError.badResponse
        }
        return decoded
    }

    /// `POST /events` — upload a delta batch. Longer timeout: a first-enable drain can carry
    /// a full 2000-event batch.
    func postEvents(_ batch: RecUploadBatch, key: String, profileId: String) async throws -> RecUploadResponse {
        let body = try JSONEncoder().encode(batch)
        return try await run(
            try request("events", method: "POST", key: key, profileId: profileId,
                        body: body, timeout: 30),
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
    func deleteState(key: String, profileId: String) async throws {
        struct Ack: Decodable { let deleted: Bool? }
        _ = try await run(
            try request("state", method: "DELETE", key: key, profileId: profileId),
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
