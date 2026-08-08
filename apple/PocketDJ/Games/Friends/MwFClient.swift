import Foundation

/// The per-install Music-with-Friends RE-JOIN credential — 32 random hex chars minted on
/// first use and persisted under `pdj.mwf.joinSecret.v1`.
///
/// Deliberately NOT `DeviceIdentity.current`: that id is a broadcast correlation value (it
/// rides every server call as `X-PocketDJ-Device` and the broker hands it to jukebox hosts
/// in `/requests`), so a server that accepted it as proof-of-identity would hand a member's
/// bearer `memberKey` to anyone who ever saw it. This value goes to exactly ONE endpoint
/// (`POST /mwf/:id/join`), where the broker stores only its sha256.
enum MwFJoinSecret {
    private static let defaultsKey = "pdj.mwf.joinSecret.v1"

    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty { return existing }
        let minted = (0..<32).map { _ in "0123456789abcdef".randomElement()! }.map(String.init).joined()
        defaults.set(minted, forKey: defaultsKey)
        return minted
    }

    /// Account deletion (the `DeviceIdentity.reset()` sibling): forget the secret so the next
    /// join mints a fresh one. Without this, re-joining a previously joined session would
    /// server-side sha256-match the OLD secret and silently resurrect the deleted account's
    /// memberId + display name.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// Thin async client for the broker's Music with Friends routes (`/mwf/...` on the SAME
/// jukebox server — `SettingsStore.jukeboxServerURL` / `jukeboxToken`, no new settings).
/// Mirrors `JukeboxClient`: injectable URLSession, short timeouts, per-call bearer,
/// `PDJIdentityHeaders` on every request.
struct MwFClient {
    var baseURL: String
    /// Server-level bearer for `POST /mwf` (create only; empty = server runs open).
    var token: String
    var profileId: String = ""
    var session: URLSession = .shared

    typealias ClientError = JukeboxClient.ClientError

    private var base: String {
        baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func request(base: String? = nil, _ path: String, method: String, bearer: String?,
                         body: (any Encodable)? = nil, timeout: TimeInterval = 12) throws -> URLRequest {
        let b = (base ?? self.base)
        guard !b.isEmpty, let url = URL(string: "\(b)\(path)") else { throw ClientError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let bearer, !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
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

    /// `POST /mwf` — create a session (leader). Longer timeout: two S3 uploads.
    struct CreateResult: Decodable {
        var sessionId: String?
        var leaderKey: String?
        var memberId: String?
        var memberKey: String?
        var name: String?
        var theme: String?
        var url: String?
        var expiresAt: Double?
        var settings: MwFSettings?
    }

    func create(name: String, theme: String, leaderName: String, clientId: String,
                joinSecret: String, settings: MwFSettings) async throws -> CreateResult {
        struct Body: Encodable {
            let name: String; let theme: String; let leaderName: String
            let clientId: String; let joinSecret: String; let settings: MwFSettings
        }
        return try await run(
            try request("/mwf", method: "POST", bearer: token,
                        body: Body(name: name, theme: theme, leaderName: leaderName,
                                   clientId: clientId, joinSecret: joinSecret, settings: settings),
                        timeout: 30),
            as: CreateResult.self)
    }

    /// `POST /mwf/:id/join` — public, idempotent by the per-install `joinSecret` (NOT the
    /// broadcast clientId, which the server refuses as proof of identity). A device that
    /// still holds a `memberKey` presents it as the bearer, which re-binds that exact
    /// member. `apiBase` comes from the public state.json (like `submitGuestRequest`),
    /// falling back to the configured server.
    struct JoinResult: Decodable {
        var memberId: String?
        var memberKey: String?
        var name: String?
        var theme: String?
        var settings: MwFSettings?
        var expiresAt: Double?
        var sessionName: String?
    }

    func join(apiBase: String?, sessionId: String, name: String, clientId: String,
              joinSecret: String, memberKey: String? = nil) async throws -> JoinResult {
        struct Body: Encodable { let name: String; let clientId: String; let joinSecret: String }
        let b = normalizedBase(apiBase)
        return try await run(
            try request(base: b, "/mwf/\(sessionId)/join", method: "POST", bearer: memberKey,
                        body: Body(name: name, clientId: clientId, joinSecret: joinSecret)),
            as: JoinResult.self)
    }

    /// `GET /mwf/:id/state` — member-private state (memberKey OR leaderKey bearer).
    func state(_ entry: MwFSessionEntry) async throws -> MwFState {
        try await run(
            try request(base: normalizedBase(entry.apiBase), "/mwf/\(entry.id)/state",
                        method: "GET", bearer: entry.memberKey),
            as: MwFState.self)
    }

    /// Public `state.json` off CloudFront (cache-busting, no auth).
    func publicState(url: URL) async throws -> MwFState {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        PDJIdentityHeaders.apply(to: &req, profileId: profileId)
        return try await run(req, as: MwFState.self)
    }

    struct SuggestResult: Decodable {
        var suggestionId: String?
        var status: String?
        var turnAdvanced: Bool?
    }

    func suggest(_ entry: MwFSessionEntry, title: String, artist: String) async throws -> SuggestResult {
        struct Body: Encodable { let title: String; let artist: String }
        return try await run(
            try request(base: normalizedBase(entry.apiBase), "/mwf/\(entry.id)/suggest",
                        method: "POST", bearer: entry.memberKey,
                        body: Body(title: title, artist: artist)),
            as: SuggestResult.self)
    }

    /// Leader verdict on a pending suggestion (`accepted` carries the local match).
    func decide(_ entry: MwFSessionEntry, suggestionId: String, action: String,
                match: MwFMatch?) async throws {
        struct Body: Encodable { let action: String; let match: MwFMatch? }
        struct Ack: Decodable { let ok: Bool? }
        guard let leaderKey = entry.leaderKey else { throw ClientError.http(401) }
        _ = try await run(
            try request(base: normalizedBase(entry.apiBase),
                        "/mwf/\(entry.id)/suggestions/\(suggestionId)/decision",
                        method: "POST", bearer: leaderKey,
                        body: Body(action: action, match: match)),
            as: Ack.self)
    }

    func plusOne(_ entry: MwFSessionEntry, suggestionId: String) async throws {
        struct Ack: Decodable { let ok: Bool? }
        _ = try await run(
            try request(base: normalizedBase(entry.apiBase),
                        "/mwf/\(entry.id)/suggestions/\(suggestionId)/plusone",
                        method: "POST", bearer: entry.memberKey),
            as: Ack.self)
    }

    /// Leader-only partial settings update (turnSeconds applies from the NEXT turn).
    func configure(_ entry: MwFSessionEntry, settings: MwFSettings) async throws -> MwFSettings {
        struct Reply: Decodable { let settings: MwFSettings? }
        guard let leaderKey = entry.leaderKey else { throw ClientError.http(401) }
        let r = try await run(
            try request(base: normalizedBase(entry.apiBase), "/mwf/\(entry.id)/config",
                        method: "POST", bearer: leaderKey, body: settings),
            as: Reply.self)
        return r.settings ?? settings
    }

    func registerDevice(_ entry: MwFSessionEntry, platform: String, token deviceToken: String) async throws {
        struct Body: Encodable { let platform: String; let token: String }
        struct Ack: Decodable { let ok: Bool? }
        _ = try await run(
            try request(base: normalizedBase(entry.apiBase), "/mwf/\(entry.id)/register-device",
                        method: "POST", bearer: entry.memberKey,
                        body: Body(platform: platform, token: deviceToken)),
            as: Ack.self)
    }

    func end(_ entry: MwFSessionEntry) async throws {
        struct Ack: Decodable { let ok: Bool? }
        guard let leaderKey = entry.leaderKey else { throw ClientError.http(401) }
        _ = try await run(
            try request(base: normalizedBase(entry.apiBase), "/mwf/\(entry.id)/end",
                        method: "POST", bearer: leaderKey, timeout: 30),
            as: Ack.self)
    }

    /// A non-empty apiBase (from state.json) wins; else the configured server base.
    private func normalizedBase(_ apiBase: String?) -> String {
        let trimmed = (apiBase ?? "").trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? base : trimmed
    }
}
