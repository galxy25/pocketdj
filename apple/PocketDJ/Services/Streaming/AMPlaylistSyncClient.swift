import Foundation

/// HTTP client for the WS2 Apple Music playlist-sync Lambda (bidirectional PocketDJ ↔ Apple Music
/// library playlists). PULL reads the user's AM library playlists; PUSH is IDEMPOTENT server-side:
/// it creates a playlist only when no same-named one exists and otherwise appends only the missing
/// tracks — re-running a partial sync tops a playlist up, never duplicates it. Removals/reorders of
/// an existing AM playlist are an ON-DEVICE MusicKit concern (see `PlaylistWriteBack.reconcile`).
/// The per-user Music-User-Token is minted on-device by `MusicUserTokenService` and sent per call;
/// the server never stores it.
///
/// ── Async job + poll + resume (why) ─────────────────────────────────────────────────────────────
/// A real library sync is hundreds of sequential Apple Music calls — far beyond API Gateway's hard
/// 30s timeout (the old 503) and, for a big library, beyond a fixed client deadline (the old
/// "timed out"). So: POST /pull|/push returns `{jobId}` (202) in <1s; the server works in
/// CHECKPOINTED chunks, chaining Lambda continuations for as long as it needs, publishing progress
/// ({label, done, total}) with every checkpoint; and this client polls `GET /job/{jobId}`,
/// surfacing that progress and giving up only when progress STALLS (~3 min with no advance), not
/// on a wall clock. The active jobId is remembered (UserDefaults), so a re-tap — or an app
/// relaunch — RE-ATTACHES to the running job instead of starting the sync over.
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
        /// Per-catalog-id song identity for the server's NAME+ARTIST duplicate gate — the same
        /// recording can live under several catalog ids, so the server must be able to refuse an
        /// append whose identity already exists remotely.
        var trackMeta: [TrackMeta] = []
        /// The LOCAL collections that folded into this entry — so the push result's Apple Music
        /// playlist id can be stamped back onto each of them as a durable link. Not sent to the
        /// server; purely a round-trip handle.
        var localPlaylistIds: [String] = []
        var localPocketIds: [String] = []
        struct TrackMeta: Equatable {
            var id: String
            var n: String
            var a: String
        }
    }
    /// One per-playlist outcome from the idempotent push: `created` says whether the playlist was
    /// newly made in Apple Music (vs. matched to an existing one); `added` is how many tracks this
    /// sync actually appended (0 = it was already complete).
    struct PushResult: Decodable, Equatable {
        struct Row: Decodable, Equatable {
            let name: String
            let id: String?
            let created: Bool
            let added: Int
            let total: Int?
        }
        struct Failure: Decodable, Equatable { let name: String; let error: String }
        let playlists: [Row]
        let errors: [Failure]
    }

    /// Server-published progress for a running job — feeds the step-by-step sync UI.
    struct JobProgress: Decodable, Equatable {
        let label: String
        let done: Int?
        let total: Int?
        var display: String {
            if let done, let total, total > 0 { return "\(label) (\(done)/\(total))" }
            if let done, done > 0 { return "\(label) (\(done))" }
            return label
        }
    }

    private struct JobSubmit: Decodable { let jobId: String }
    private struct JobEnvelope<T: Decodable>: Decodable {
        let status: String          // "pending" | "running" | "done" | "error"
        let progress: JobProgress?
        let result: T?
        let error: String?
    }

    enum ClientError: LocalizedError {
        case http(Int, String)
        case stalled(String)
        case worker(String)
        case jobGone
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg):
                return "Apple Music sync failed (HTTP \(code))\(msg.isEmpty ? "" : ": \(msg.prefix(200))")"
            case .stalled(let last):
                return "Apple Music sync stopped making progress (last step: \(last)). Tap Sync to resume where it left off."
            case .worker(let msg):
                return "Apple Music sync failed: \(msg.prefix(240))"
            case .jobGone:
                return "The previous sync expired — tap Sync to start again."
            }
        }
    }

    private let base: URL
    private let tokens: MusicUserTokenService
    /// Give up when the server publishes NO new progress for this long (a healthy large sync
    /// advances every few seconds; three quiet minutes means the backend truly died).
    private let stallTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let defaults: UserDefaults

    init(base: URL = Config.amPlaylistSyncBase,
         tokens: MusicUserTokenService? = nil,
         stallTimeout: TimeInterval = 180,
         pollInterval: TimeInterval = 2,
         defaults: UserDefaults = .standard) {
        self.base = base
        self.tokens = tokens ?? MusicUserTokenService(base: base)
        self.stallTimeout = stallTimeout
        self.pollInterval = pollInterval
        self.defaults = defaults
    }

    /// PULL — the user's Apple Music library playlists (with catalog track ids where available).
    func pull(onProgress: ((JobProgress) -> Void)? = nil) async throws -> [RemotePlaylist] {
        let result: PullResponse = try await runJob(op: "pull", body: nil, onProgress: onProgress)
        return result.playlists
    }

    /// PUSH — idempotently mirror the given PocketDJ playlists into the Apple Music library
    /// (create-if-absent + append-only-missing; server-side).
    func push(_ playlists: [OutgoingPlaylist],
              onProgress: ((JobProgress) -> Void)? = nil) async throws -> PushResult {
        guard !playlists.isEmpty else { return PushResult(playlists: [], errors: []) }
        let payload: [[String: Any]] = playlists.map { pl in
            var d: [String: Any] = ["name": pl.name, "trackCatalogIds": pl.trackCatalogIds]
            if let description = pl.description { d["description"] = description }
            if !pl.trackMeta.isEmpty {
                d["trackMeta"] = pl.trackMeta.map { ["id": $0.id, "n": $0.n, "a": $0.a] }
            }
            return d
        }
        return try await runJob(op: "push", body: ["playlists": payload], onProgress: onProgress)
    }

    // MARK: - Job lifecycle (attach-or-submit, then poll)

    private func activeJobKey(_ op: String) -> String { "pdj.amsync.activeJob.\(op)" }

    /// A still-plausible jobId from a previous attempt (jobs expire server-side after a day; we
    /// re-attach within the hour — beyond that a fresh sync is cheaper than a stale result).
    private func storedJob(_ op: String) -> String? {
        guard let d = defaults.dictionary(forKey: activeJobKey(op)),
              let id = d["jobId"] as? String,
              let at = d["at"] as? TimeInterval,
              Date().timeIntervalSince1970 - at < 3600 else { return nil }
        return id
    }
    private func storeJob(_ op: String, _ jobId: String) {
        defaults.set(["jobId": jobId, "at": Date().timeIntervalSince1970], forKey: activeJobKey(op))
    }
    private func clearJob(_ op: String) { defaults.removeObject(forKey: activeJobKey(op)) }

    /// Is this error PROOF the job is dead server-side? Only then may the stored jobId be
    /// cleared. Anything else — a Wi-Fi blip, a gateway 502, a stall — must keep the id so the
    /// next attempt RE-ATTACHES: clearing it and resubmitting while the server-side worker chain
    /// is still alive runs TWO pushes concurrently against the same library (double-appends).
    private func isTerminal(_ error: Error) -> Bool {
        switch error as? ClientError {
        case .jobGone, .worker: return true
        case .http(let code, _): return (400...499).contains(code)
        default: return false
        }
    }

    private func runJob<T: Decodable>(op: String, body: [String: Any]?,
                                      onProgress: ((JobProgress) -> Void)?) async throws -> T {
        // RESUME: an unfinished job from a previous tap/launch — attach to it rather than
        // re-submitting (prevents double work AND double pushes).
        if let existing = storedJob(op) {
            do {
                let result: T = try await poll(existing, onProgress: onProgress)
                clearJob(op)
                return result
            } catch {
                guard isTerminal(error) else { throw error }  // stall/transient: id survives
                clearJob(op)                       // dead for sure — fall through to a fresh submit
            }
        }
        var payload = body ?? [:]
        payload["musicUserToken"] = try await tokens.musicUserToken()
        let jobId = try await submit(op, payload)
        storeJob(op, jobId)
        do {
            let result: T = try await poll(jobId, onProgress: onProgress)
            clearJob(op)
            return result
        } catch {
            if isTerminal(error) { clearJob(op) }  // otherwise the id survives for re-attach
            throw error
        }
    }

    /// POST the op and return the server-assigned jobId (the fast 202 path).
    private func submit(_ op: String, _ body: [String: Any]) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent(op))
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

    /// Poll GET /job/{jobId} until the worker finishes. The deadline is STALL-based: it resets
    /// whenever the published progress changes, so a large library can run as long as it needs.
    ///
    /// TRANSIENT failures — a URLError from a Wi-Fi→LTE handoff, a gateway 5xx/429, a torn decode —
    /// are ABSORBED (sleep and re-poll) rather than thrown: the server-side worker chain keeps
    /// running regardless of whether we're watching, so one blipped poll must never abort (and
    /// certainly never restart) a live sync. Only a 404 (job truly gone), a worker-reported error,
    /// or the stall deadline get out of this loop besides success.
    private func poll<T: Decodable>(_ jobId: String, onProgress: ((JobProgress) -> Void)?) async throws -> T {
        let jobURL = base.appendingPathComponent("job").appendingPathComponent(jobId)
        var lastProgressKey = ""
        var lastLabel = "starting"
        var stallDeadline = Date().addingTimeInterval(stallTimeout)
        while true {
            var env: JobEnvelope<T>?
            do {
                var req = URLRequest(url: jobURL)
                req.timeoutInterval = 20
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { throw ClientError.jobGone }
                if code != 200, (400...499).contains(code) {
                    throw ClientError.http(code, String(data: data, encoding: .utf8) ?? "")
                }
                guard code == 200 else { throw TransientPollError() }   // 5xx / 429 — retry
                env = try JSONDecoder().decode(JobEnvelope<T>.self, from: data)
            } catch let e as ClientError {
                throw e                     // 404 / hard 4xx — genuinely terminal
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                env = nil                   // URLError / 5xx / decode blip — treat as a missed poll
            }

            if let p = env?.progress {
                onProgress?(p)
                lastLabel = p.display
                let key = "\(p.label)|\(p.done ?? -1)|\(p.total ?? -1)"
                if key != lastProgressKey {
                    lastProgressKey = key
                    stallDeadline = Date().addingTimeInterval(stallTimeout)
                }
            }
            switch env?.status {
            case "done":
                guard let result = env?.result else { throw ClientError.worker("job finished without a result") }
                return result
            case "error":
                throw ClientError.worker(env?.error ?? "unknown worker error")
            default: // pending | running | missed poll
                if Date() >= stallDeadline { throw ClientError.stalled(lastLabel) }
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    /// Marker for a poll iteration that should be retried, never surfaced.
    private struct TransientPollError: Error {}
}
