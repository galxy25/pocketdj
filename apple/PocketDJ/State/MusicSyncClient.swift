import Foundation
import Observation

/// Apple Music (Local) sync client — talks to the iMac rip server's AM-sync endpoints to
/// keep the app's "Apple Music (Local)" data source in step with the real local library.
///
/// Mirrors `RipsStore`'s server contract: the rip-server URL + bearer token come from
/// `SettingsStore` (the SAME ones the rip features use), and the request/poll shape mirrors
/// the rip job pattern (POST → jobId, GET poll-by-id):
///   • POST `/am-sync`        → `{ jobId, phase }` (returns immediately; the check runs server-side),
///   • GET  `/am-sync/<id>`   → `{ phase, result }` polled until `phase == .ready` (or `.error`).
///
/// The server does the library read + diff (via the incremental Apple Music indexer) and, when
/// it finds new music, writes a change-set to its `~/Downloads` for the cron Claude-agent to
/// commit + deploy. The app's `sync()` surfaces the DETECTED counts immediately for feedback;
/// the live `apple-music-index.json` only changes once that agent has committed+pushed+deployed.
@MainActor
@Observable
final class MusicSyncClient {
    /// The AM-sync job phases (match the server's `queued → scanning → diffing → ready | error`).
    enum Phase: String, Decodable {
        case queued, scanning, diffing, ready, error
    }

    /// One added/changed/removed item in a sync result.
    struct SyncItem: Decodable, Equatable {
        var songId: String
        var albumId: String?
        var title: String?
        var artist: String?
        /// "added" | "changed" | "removed".
        var change: String?
    }

    /// The result-set counts (`added`/`changed`/`removed`).
    struct SyncCounts: Decodable, Equatable {
        var added = 0
        var changed = 0
        var removed = 0
    }

    /// The `/am-sync/<id>` `result` object (null until `phase == .ready`).
    struct SyncResult: Decodable, Equatable {
        var counts: SyncCounts
        var added: [SyncItem] = []
        var changed: [SyncItem] = []
        var removed: [SyncItem] = []
        /// Absolute path of the change-set the server wrote to its Downloads (nil if 0 added).
        var changeSetPath: String?
    }

    /// The `POST /am-sync` accept response.
    private struct SyncJob: Decodable {
        var jobId: String?
        var phase: Phase?
    }

    /// The `GET /am-sync/<id>` poll response.
    private struct SyncJobView: Decodable {
        var jobId: String?
        var phase: Phase
        var message: String?
        var error: String?
        var result: SyncResult?
    }

    // MARK: Config (mirror RipsStore — server URL + token from settings)

    private let session: URLSession
    /// Settings supply the rip-server URL + token (set by the app at launch).
    var settings: SettingsStore?

    var serverUrl: String { (settings?.ripServerURL ?? "").trimmingCharacters(in: .whitespaces).trimmedTrailingSlash }
    var token: String { (settings?.ripToken ?? "").trimmingCharacters(in: .whitespaces) }
    var hasServer: Bool { !serverUrl.isEmpty }

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Errors

    enum SyncError: LocalizedError {
        case noServer, unsupported, requestFailed(Int), serverError(String?), timedOut
        var errorDescription: String? {
            switch self {
            case .noServer:            return "No rip server configured (Settings ▸ Rip server)."
            case .unsupported:         return "Server too old — update the rip server to sync."
            case .requestFailed(let s): return "Sync request failed (\(s))."
            case .serverError(let m):  return m ?? "Sync failed."
            case .timedOut:            return "Sync timed out."
            }
        }
    }

    // MARK: Sync

    /// Kick a library check on the rip server and poll until it produces a result set. Returns
    /// the detected `added/changed/removed` counts + items. Throws `.unsupported` against an
    /// older server (404 on POST `/am-sync`), `.noServer` when unconfigured.
    @discardableResult
    func sync() async throws -> SyncResult {
        guard hasServer else { throw SyncError.noServer }
        let base = serverUrl, tok = token

        // POST /am-sync → jobId (returns immediately; the check runs server-side).
        var post = URLRequest(url: URL(string: "\(base)/am-sync")!)
        post.httpMethod = "POST"
        post.timeoutInterval = 12
        post.setValue("application/json", forHTTPHeaderField: "content-type")
        applyAuth(&post, token: tok)
        post.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: post)
        guard let http = response as? HTTPURLResponse else { throw SyncError.requestFailed(0) }
        if http.statusCode == 404 { throw SyncError.unsupported }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.requestFailed(http.statusCode) }
        let job = try JSONDecoder().decode(SyncJob.self, from: data)
        guard let jobId = job.jobId else { throw SyncError.serverError("server returned no job id") }

        // Poll GET /am-sync/<id> until ready/error. The scan is a local XML diff (fast), so a
        // 1s cadence with a generous cap is plenty.
        for _ in 0..<600 {
            try await Self.sleep1s()
            guard let view = try? await fetchJob(jobId, base: base, token: tok) else { continue }
            switch view.phase {
            case .ready:
                if let result = view.result { return result }
                return SyncResult(counts: SyncCounts())
            case .error:
                throw SyncError.serverError(view.error)
            default:
                continue
            }
        }
        throw SyncError.timedOut
    }

    private func fetchJob(_ jobId: String, base: String, token: String) async throws -> SyncJobView {
        let id = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        var request = URLRequest(url: URL(string: "\(base)/am-sync/\(id)")!)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError.serverError(nil)
        }
        return try JSONDecoder().decode(SyncJobView.self, from: data)
    }

    // MARK: Helpers

    private func applyAuth(_ request: inout URLRequest, token: String) {
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    static func sleep1s() async throws { try await Task.sleep(nanoseconds: 1_000_000_000) }
}

private extension String {
    /// Trim a single trailing slash (matches RipsStore / the PWA's `replace(/\/$/, '')`).
    var trimmedTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
