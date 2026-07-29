import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

/// Captures the per-user Apple Music MUSIC-USER-TOKEN so the server-side playlist-sync Lambda can
/// act on THIS user's library (WS2). MusicKit hides the token inside `MusicDataRequest` for
/// on-device calls; to hand it to our OWN backend we mint it explicitly via `MusicUserTokenProvider`
/// (iOS 15+/visionOS 1.0+ — deliberately NOT the deprecated, visionOS-absent StoreKit
/// `SKCloudServiceController.requestUserToken`). The token is rotating/revocable and minted PER SYNC
/// (never stored) — on a 401/403 the caller simply re-mints.
///
/// Requires MusicKit enabled (`AppleMusicCredentials.isEnabled`), an ACTIVE Apple Music
/// subscription, and prior `MusicAuthorization` consent. The Simulator cannot mint a real token —
/// this is a device-only capability (the sync UI surfaces the thrown error).
@MainActor
final class MusicUserTokenService {
    private struct DeveloperTokenResponse: Decodable { let token: String; let expiresAt: Double }

    enum TokenError: LocalizedError {
        case notEnabled, notAuthorized, developerTokenFailed, userTokenUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .notEnabled:                return "Apple Music isn’t enabled in this build."
            case .notAuthorized:             return "Grant Apple Music access first (Settings ▸ Streaming)."
            case .developerTokenFailed:      return "Couldn’t reach the Apple Music sync service."
            case .userTokenUnavailable(let m): return "Couldn’t get an Apple Music token: \(m)"
            }
        }
    }

    private let base: URL
    private var cachedDevToken: (token: String, expMs: Double)?

    init(base: URL = Config.amPlaylistSyncBase) { self.base = base }

    /// App-wide developer token from the sync Lambda (`GET /musickit-token`), cached until it has
    /// < 7 days of life. It's app-wide + low-value on its own (useless without a user token).
    func developerToken() async throws -> String {
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let c = cachedDevToken, c.expMs - nowMs > 7 * 24 * 3600 * 1000 { return c.token }
        var req = URLRequest(url: base.appendingPathComponent("musickit-token"))
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let dt = try? JSONDecoder().decode(DeveloperTokenResponse.self, from: data) else {
            throw TokenError.developerTokenFailed
        }
        cachedDevToken = (dt.token, dt.expiresAt)
        return dt.token
    }

    /// Mint the per-user Music-User-Token. DEVICE-ONLY — throws on the Simulator, with no active
    /// subscription, or without prior authorization.
    func musicUserToken() async throws -> String {
        #if canImport(MusicKit)
        guard AppleMusicCredentials.isEnabled else { throw TokenError.notEnabled }
        guard MusicAuthorization.currentStatus == .authorized else { throw TokenError.notAuthorized }
        let developer = try await developerToken()
        do {
            return try await MusicUserTokenProvider().userToken(for: developer, options: [])
        } catch {
            throw TokenError.userTokenUnavailable(error.localizedDescription)
        }
        #else
        throw TokenError.notEnabled
        #endif
    }
}
