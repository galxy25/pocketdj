import Foundation

/// HTTP client for the WS2 Apple Music playlist-sync Lambda (bidirectional PocketDJ ↔ Apple Music
/// library playlists). PULL reads the user's AM library playlists; PUSH creates AM playlists from
/// PocketDJ ones. The server is CREATE + APPEND only — reorder/remove of an existing AM playlist is
/// an ON-DEVICE MusicKit concern (see `PlaylistWriteBack` / `MusicLibrary.edit`), so this client's
/// push is create-with-ordered-tracks. The per-user Music-User-Token is minted on-device by
/// `MusicUserTokenService` and sent per call; the server never stores it.
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

    enum ClientError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case .http(let code, let msg) = self {
                return "Apple Music sync failed (HTTP \(code))\(msg.isEmpty ? "" : ": \(msg.prefix(200))")"
            }
            return "Apple Music sync failed"
        }
    }

    private let base: URL
    private let tokens: MusicUserTokenService

    init(base: URL = Config.amPlaylistSyncBase, tokens: MusicUserTokenService? = nil) {
        self.base = base
        self.tokens = tokens ?? MusicUserTokenService(base: base)
    }

    /// PULL — the user's Apple Music library playlists (with catalog track ids where available).
    func pull() async throws -> [RemotePlaylist] {
        let mut = try await tokens.musicUserToken()
        let data = try await post("pull", ["musicUserToken": mut])
        return try JSONDecoder().decode(PullResponse.self, from: data).playlists
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
        let data = try await post("push", ["musicUserToken": mut, "playlists": payload])
        return try JSONDecoder().decode(PushResult.self, from: data)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ClientError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }
}
