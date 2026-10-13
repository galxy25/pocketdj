import Foundation

/// Thin async client for the listening-pockets Lambda (`pocketdj-listening-pockets`, mounted at
/// `/pockets` on the SAME HTTP API as the rec engine — `Config.listeningPocketsBase`). Shaped
/// exactly like `RecEngineClient`: not `@MainActor`, short timeouts, injectable transport.
///
/// Auth is the rec engine's, verbatim: `Authorization: Bearer <per-profile key>` plus the
/// rec-engine-SCOPED profile id (`HMAC-SHA256(profileId, key: bearer)`, never the broadcast one)
/// in `X-PocketDJ-Profile`, and the enrollment secret on the two routes that can create or
/// destroy state (POST /pockets/events, DELETE /pockets/state). The server binds its own TOFU
/// copy of the key in its own S3 object, so the pockets and rec states are independent.
///
/// A 404 is its own case (`.notFound`): until the pockets routes are deployed the rec engine's
/// `$default` route answers every `/pockets/*` path with not-found, and the service must read
/// that as "not available yet", silently — not as a sync error.
struct ListeningPocketsClient {
    /// Injected base (tests); nil ⇒ `Config.listeningPocketsBase` read LIVE per request.
    var base: URL? = nil
    private var resolvedBase: URL { base ?? Config.listeningPocketsBase }
    var enrollSecret: String = Config.recEngineEnrollSecret
    var transport: (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    enum ClientError: Error, Equatable {
        case http(Int)
        /// 404 — the pockets routes are not deployed (or the path is wrong). Not a user error.
        case notFound
        case keyMismatch
        case enrollmentRequired
        case profileCapReached
        case badResponse
    }

    private func request(_ path: String, method: String, key: String, profileId: String,
                         body: Data? = nil, timeout: TimeInterval = 20,
                         enroll: Bool = false) throws -> URLRequest {
        var req = URLRequest(url: resolvedBase.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if enroll, !enrollSecret.isEmpty {
            req.setValue(enrollSecret, forHTTPHeaderField: RecEngineClient.enrollHeader)
        }
        PDJIdentityHeaders.apply(to: &req, profileId: profileId)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// Run a request → the 2xx body, with the 403 / 404 bodies mapped to distinct errors.
    private func runRaw(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await transport(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw Self.map403(data) }
        if code == 404 { throw ClientError.notFound }
        guard (200..<300).contains(code) else { throw ClientError.http(code) }
        return data
    }

    private static func map403(_ body: Data) -> ClientError {
        struct Err: Decodable { let error: String? }
        switch (try? JSONDecoder().decode(Err.self, from: body))?.error {
        case "enrollment-required": return .enrollmentRequired
        case "profile-cap-reached": return .profileCapReached
        default:                    return .keyMismatch
        }
    }

    /// `POST /pockets/events` — upload a batch (≤1000 events from this client; the server caps
    /// at 2000). Carries the enrollment secret: the first upload creates the profile's state.
    func postEvents(_ batch: ListeningPocketsUploadBatch, key: String,
                    profileId: String) async throws -> ListeningPocketsUploadResponse {
        let body = try JSONEncoder().encode(batch)
        let data = try await runRaw(try request("pockets/events", method: "POST", key: key,
                                                profileId: profileId, body: body, timeout: 30,
                                                enroll: true))
        return (try? JSONDecoder().decode(ListeningPocketsUploadResponse.self, from: data))
            ?? ListeningPocketsUploadResponse()
    }

    /// `POST /pockets/rounds` — upload finished "In the Pocket" rounds (≤ 50 per batch). Same auth
    /// and enrollment as `postEvents` (the game can be a profile's first upload). A 404 means the
    /// route isn't deployed yet — the caller keeps the rounds queued.
    func postRounds(_ batch: InThePocketRoundsBatch, key: String,
                    profileId: String) async throws -> ListeningPocketsUploadResponse {
        let body = try JSONEncoder().encode(batch)
        let data = try await runRaw(try request("pockets/rounds", method: "POST", key: key,
                                                profileId: profileId, body: body, timeout: 30,
                                                enroll: true))
        return (try? JSONDecoder().decode(ListeningPocketsUploadResponse.self, from: data))
            ?? ListeningPocketsUploadResponse()
    }

    /// `GET /pockets/results` — the decoded document AND its raw bytes (the service caches the
    /// bytes so the tab renders offline, and re-decodes them with this same lenient decoder).
    func results(key: String, profileId: String) async throws -> (ListeningPocketsResults, Data) {
        let data = try await runRaw(try request("pockets/results", method: "GET", key: key,
                                                profileId: profileId))
        guard let decoded = try? JSONDecoder().decode(ListeningPocketsResults.self, from: data) else {
            throw ClientError.badResponse
        }
        return (decoded, data)
    }

    /// `DELETE /pockets/state` — erase this profile's pockets events + results ("Delete cloud
    /// data"). The enrollment secret authorizes it even when the key no longer matches.
    func deleteState(key: String, profileId: String) async throws {
        _ = try await runRaw(try request("pockets/state", method: "DELETE", key: key,
                                         profileId: profileId, enroll: true))
    }

    /// `GET /pockets/health` — unauthenticated reachability probe.
    func health() async -> Bool {
        struct Health: Decodable { let ok: Bool?; let service: String? }
        var req = URLRequest(url: resolvedBase.appendingPathComponent("pockets/health"), timeoutInterval: 12)
        req.httpMethod = "GET"
        guard let (data, resp) = try? await transport(req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let h = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        return h.ok == true
    }
}
