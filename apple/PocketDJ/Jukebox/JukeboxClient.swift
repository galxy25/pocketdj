import Foundation

/// Thin async client for the jukebox server (the session broker — see
/// docs/design/jukebox-hero.md). Follows `RipServerService`'s shape: short request
/// timeouts so an asleep/unreachable server fails fast instead of hanging the UI, an
/// injectable `URLSession` for tests, and bearer auth per call. Two credentials exist:
/// the server-level token (create only) and the per-jukebox `hostKey` (everything else).
struct JukeboxClient {
    var baseURL: String
    /// Server-level bearer for `POST /jukebox` (empty = server runs open).
    var token: String
    /// The signed-in profile's durable id (`ProfileStore.id`), snapshotted when this client is
    /// built (the struct is rebuilt per call from the live id). Empty ⇒ no profile header.
    /// Rides as `X-PocketDJ-Profile` on every jukebox call (see `request`).
    var profileId: String = ""
    var session: URLSession = .shared

    enum ClientError: Error, LocalizedError {
        case badURL
        case http(Int)
        case decoding

        var errorDescription: String? {
            switch self {
            case .badURL:      return "Jukebox server URL is invalid — check Settings."
            case .http(let c): return "Jukebox server request failed (HTTP \(c))."
            case .decoding:    return "Couldn’t read the jukebox server’s response."
            }
        }
    }

    /// `GET /health` — reachability + version, for the Settings test button and the MwF
    /// capability gate (`mwf` advertised since server v3).
    struct Health: Decodable {
        let ok: Bool?
        let service: String?
        let version: Int?
        let mwf: Bool?
    }

    private var base: String {
        baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func request(_ path: String, method: String, bearer: String?,
                         body: (any Encodable)? = nil, timeout: TimeInterval = 12) throws -> URLRequest {
        guard let url = URL(string: "\(base)\(path)") else { throw ClientError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let bearer, !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        // Per-user identity rides alongside the (host-key or server) bearer on every call.
        PDJIdentityHeaders.apply(to: &req, profileId: profileId)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ClientError.http(code) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw ClientError.decoding
        }
        return decoded
    }

    func health() async throws -> Health {
        try await run(try request("/health", method: "GET", bearer: token), as: Health.self)
    }

    /// Create a jukebox: the server mints ids, renders + uploads the guest page, and
    /// seeds `state.json`. Longer timeout — the create does two S3 uploads.
    /// `timeless: false` ⇒ the default lifecycle (auto-end 24 h, sweeper-deleted at 7 d).
    /// `requiresToken` asks the server to mint a per-session guest access token and bake it
    /// into the returned `url`. #TOUPDATE: the server ignores this field today (it returns a
    /// bare public URL); it rides the create call as intent so the plumbing is ready when
    /// jukebox-server.mjs starts minting + enforcing the guest token.
    func create(name: String, timeless: Bool, requiresToken: Bool) async throws -> JukeboxSessionInfo {
        struct Body: Encodable { let name: String; let timeless: Bool; let requiresToken: Bool }
        return try await run(
            try request("/jukebox", method: "POST", bearer: token,
                        body: Body(name: name, timeless: timeless, requiresToken: requiresToken), timeout: 30),
            as: JukeboxSessionInfo.self)
    }

    /// One row of the host's live-session list (GET /sessions — host bearer). Carries the
    /// guest URL (the QR payload); never a hostKey.
    struct SessionRow: Decodable, Identifiable, Equatable {
        let jukeboxId: String
        let name: String
        let url: URL
        let timeless: Bool?
        let expiresAt: Double?
        var id: String { jukeboxId }
    }

    /// Every live session on the broker, newest first — the TV/CarPlay "pick a session →
    /// show its QR" surfaces.
    func listSessions() async throws -> [SessionRow] {
        struct Page: Decodable { let sessions: [SessionRow] }
        return try await run(
            try request("/sessions", method: "GET", bearer: token, timeout: 15),
            as: Page.self).sessions
    }

    /// The lifecycle fields `POST …/config` returns after a timeless flip.
    struct Lifecycle: Decodable {
        let timeless: Bool?
        let expiresAt: Double?
    }

    /// Flip the session's timeless mode; returns the updated lifecycle for local merge.
    func configure(_ s: JukeboxSessionInfo, timeless: Bool) async throws -> Lifecycle {
        struct Body: Encodable { let timeless: Bool }
        return try await run(
            try request("/jukebox/\(s.jukeboxId)/config", method: "POST", bearer: s.hostKey,
                        body: Body(timeless: timeless)),
            as: Lifecycle.self)
    }

    /// End the session — publishes a final `ended: true` state so guest pages sign off.
    func end(_ s: JukeboxSessionInfo) async throws {
        struct Ack: Decodable { let ok: Bool? }
        _ = try await run(
            try request("/jukebox/\(s.jukeboxId)/end", method: "POST", bearer: s.hostKey, timeout: 30),
            as: Ack.self)
    }

    /// Post a player snapshot. The server debounces + merges + publishes to S3.
    func postState(_ s: JukeboxSessionInfo, payload: JukeboxStatePayload) async throws {
        struct Ack: Decodable { let ok: Bool? }
        _ = try await run(
            try request("/jukebox/\(s.jukeboxId)/state", method: "POST", bearer: s.hostKey, body: payload),
            as: Ack.self)
    }

    struct RequestsPage: Decodable {
        let requests: [JukeboxRequest]
        let seq: Int
    }

    /// Poll guest requests newer than `since` (the last page's `seq`; 0 = from the top).
    func requests(_ s: JukeboxSessionInfo, since: Int) async throws -> RequestsPage {
        try await run(
            try request("/jukebox/\(s.jukeboxId)/requests?since=\(since)", method: "GET", bearer: s.hostKey),
            as: RequestsPage.self)
    }

    /// Post the host's verdict; the server flips the request's guest-visible status.
    func decide(_ s: JukeboxSessionInfo, requestId: String, action: JukeboxDecisionAction) async throws {
        struct Body: Encodable { let action: String }
        struct Ack: Decodable { let ok: Bool? }
        _ = try await run(
            try request("/jukebox/\(s.jukeboxId)/requests/\(requestId)/decision", method: "POST",
                        bearer: s.hostKey, body: Body(action: action.rawValue)),
            as: Ack.self)
    }

    // MARK: - Guest / client join (join an in-progress jukebox via link — NO hostKey)
    //
    // A device that JOINED a jukebox via a shared link (`JukeboxLink`) acts as a CLIENT: it reads
    // the SAME public `state.json` the web guests do (straight off CloudFront, no auth) and posts
    // requests to the broker's public request endpoint. It never holds the `hostKey` — only the
    // device that STARTED the jukebox is the lead. These two verbs hit ABSOLUTE URLs (the guest
    // CloudFront object + the broker's public request base), not the host `base`, so they bypass
    // the bearer plumbing above (identity headers still ride for forward-compat attribution).

    /// Read a jukebox's public `state.json` (from CloudFront) — `<guestBase>/<id>/state.json`, via
    /// `JukeboxLink.stateURL`. No auth (public object); cache-busting so a joined client sees the
    /// live now-playing rather than a stale CDN copy.
    func guestState(url: URL) async throws -> JukeboxGuestState {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        PDJIdentityHeaders.apply(to: &req, profileId: profileId)
        return try await run(req, as: JukeboxGuestState.self)
    }

    /// Submit a guest song request to the broker's PUBLIC request endpoint, mirroring the web guest
    /// page's `POST <apiBase>/jukebox/<id>/request` (rate-limited, no auth). `clientId` is a stable
    /// per-install id so the server's per-client pacing + "my requests" tracking work.
    func submitGuestRequest(apiBase: String, jukeboxId: String,
                            title: String, artist: String, clientId: String) async throws {
        let trimmed = apiBase.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/jukebox/\(jukeboxId)/request") else {
            throw ClientError.badURL
        }
        struct Body: Encodable { let title: String; let artist: String; let clientId: String }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        PDJIdentityHeaders.apply(to: &req, profileId: profileId)
        req.httpBody = try JSONEncoder().encode(Body(title: title, artist: artist, clientId: clientId))
        struct Ack: Decodable { let ok: Bool? }
        _ = try await run(req, as: Ack.self)
    }
}
