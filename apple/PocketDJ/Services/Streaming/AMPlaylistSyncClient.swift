import Foundation

/// HTTP client for the WS2 Apple Music playlist-sync Lambda (bidirectional PocketDJ ↔ Apple Music
/// library playlists). PULL reads the user's AM library playlists; PUSH creates AM playlists from
/// PocketDJ ones. The server is CREATE + APPEND only — reorder/remove of an existing AM playlist is
/// an ON-DEVICE MusicKit concern (see `PlaylistWriteBack` / `MusicLibrary.edit`), so this client's
/// push is create-with-ordered-tracks. The per-user Music-User-Token is minted on-device by
/// `MusicUserTokenService` and sent per call; the server never stores it.
///
/// ── Async job + poll (why) ──────────────────────────────────────────────────────────────────────
/// A real library pull is >100 sequential Apple Music calls and blows past API Gateway's hard 30s
/// integration timeout → the caller saw a 503. So the server is now submit-then-poll: POST /pull|/push
/// returns `{ jobId }` (HTTP 202) in <1s, a background worker does the long work, and this client
/// POLLS `GET /job/{jobId}` every ~2s until the job reports `done` (or `error`). No single request is
/// ever long enough to hit the gateway timeout.
@MainActor
final class AMPlaylistSyncClient {

    struct RemotePlaylist: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var canEdit: Bool?
        var description: String?
        var trackCatalogIds: [String]
        var trackTitles: [String]?
    }
    private struct PullResponse: Decodable { let storefront: String; let playlists: [RemotePlaylist] }

    struct OutgoingPlaylist: Equatable {
        var name: String
        var description: String?
        var trackCatalogIds: [String]
    }
    struct PushResult: Decodable, Equatable {
        struct Created: Decodable, Equatable { let name: String; let id: String? }
        struct Failure: Decodable, Equatable { let name: String; let error: String }
        let created: [Created]
        let errors: [Failure]
    }

    // Envelope the server writes to the job store and returns from GET /job/{jobId}.
    private struct JobSubmit: Decodable { let jobId: String }
    private struct JobEnvelope<T: Decodable>: Decodable {
        let status: String          // "pending" | "done" | "error"
        let result: T?
        let error: String?
    }

    enum ClientError: LocalizedError {
        case http(Int, String)
        case timedOut
        case worker(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg):
                return "Apple Music sync failed (HTTP \(code))\(msg.isEmpty ? "" : ": \(msg.prefix(200))")"
            case .timedOut:
                return "Apple Music sync timed out. Your library may be large — please try again."
            case .worker(let msg):
                return "Apple Music sync failed: \(msg.prefix(240))"
            }
        }
    }

    private let base: URL
    private let tokens: MusicUserTokenService
    /// How long to keep polling a submitted job before giving up.
    private let pollTimeout: TimeInterval
    private let pollInterval: TimeInterval

    init(base: URL = Config.amPlaylistSyncBase,
         tokens: MusicUserTokenService? = nil,
         pollTimeout: TimeInterval = 240,
         pollInterval: TimeInterval = 2) {
        self.base = base
        self.tokens = tokens ?? MusicUserTokenService(base: base)
        self.pollTimeout = pollTimeout
        self.pollInterval = pollInterval
    }

    /// PULL — the user's Apple Music library playlists (with catalog track ids where available).
    func pull() async throws -> [RemotePlaylist] {
        let mut = try await tokens.musicUserToken()
        let jobId = try await submit("pull", ["musicUserToken": mut])
        let result: PullResponse = try await poll(jobId)
        return result.playlists
    }

    /// PUSH — create Apple Music library playlists mirroring the given PocketDJ playlists.
    func push(_ playlists: [OutgoingPlaylist]) async throws -> PushResult {
        guard !playlists.isEmpty else { return PushResult(created: [], errors: []) }
        let mut = try await tokens.musicUserToken()
        let payload: [[String: Any]] = playlists.map { pl in
            var d: [String: Any] = ["name": pl.name, "trackCatalogIds": pl.trackCatalogIds]
            if let description = pl.description { d["description"] = description }
            return d
        }
        let jobId = try await submit("push", ["musicUserToken": mut, "playlists": payload])
        return try await poll(jobId)
    }

    // MARK: - Job submit + poll

    /// POST the op and return the server-assigned jobId (accepts the 202 from the fast path).
    private func submit(_ path: String, _ body: [String: Any]) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 202 else {
            throw ClientError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(JobSubmit.self, from: data).jobId
    }

    /// Poll GET /job/{jobId} until the worker finishes, then decode its `result`.
    private func poll<T: Decodable>(_ jobId: String) async throws -> T {
        let deadline = Date().addingTimeInterval(pollTimeout)
        let jobURL = base.appendingPathComponent("job").appendingPathComponent(jobId)
        while true {
            var req = URLRequest(url: jobURL)
            req.httpMethod = "GET"
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw ClientError.http(code, String(data: data, encoding: .utf8) ?? "") }
            let env = try JSONDecoder().decode(JobEnvelope<T>.self, from: data)
            switch env.status {
            case "done":
                guard let result = env.result else { throw ClientError.worker("job finished without a result") }
                return result
            case "error":
                throw ClientError.worker(env.error ?? "unknown worker error")
            default: // "pending" — keep polling until the deadline
                if Date() >= deadline { throw ClientError.timedOut }
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }
}
