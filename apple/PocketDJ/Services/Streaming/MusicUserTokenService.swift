import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

/// Seam over the thing that actually mints a Music-User-Token, so the cache/refresh policy in
/// `MusicUserTokenService` is unit-testable without MusicKit (and without a device).
protocol MusicUserTokenMinting: Sendable {
    /// `ignoreCache` ⇒ ask Apple for a FRESH token instead of MusicKit's on-device cached one.
    func userToken(developerToken: String, ignoreCache: Bool) async throws -> String
}

/// The production minter: MusicKit's `MusicUserTokenProvider` (iOS 15+/macOS 12+/tvOS 15+/
/// visionOS 1.0+ — deliberately NOT the deprecated, visionOS-absent StoreKit
/// `SKCloudServiceController.requestUserToken`).
struct MusicKitUserTokenMinter: MusicUserTokenMinting {
    func userToken(developerToken: String, ignoreCache: Bool) async throws -> String {
        #if canImport(MusicKit)
        return try await MusicUserTokenProvider().userToken(for: developerToken,
                                                            options: ignoreCache ? [.ignoreCache] : [])
        #else
        throw MusicUserTokenService.TokenError.notEnabled
        #endif
    }
}

/// Captures the per-user Apple Music MUSIC-USER-TOKEN so the server-side playlist-sync Lambda can
/// act on THIS user's library (WS2). MusicKit hides the token inside `MusicDataRequest` for
/// on-device calls; to hand it to our OWN backend we mint it explicitly via `MusicUserTokenProvider`.
/// The server never stores it: every pull/push job submit carries the token, so a new token
/// reaches the server simply by being sent with the next (re)submitted job.
///
/// ── Why `.ignoreCache` (2026-10-29, Q25) ───────────────────────────────────────────────────────
/// MusicKit's CACHED token (`options: []`) can be one the Apple Music REST API rejects with
/// `403 40300 Invalid authentication` while in-app MusicKit playback/`MusicDataRequest` keep
/// working — every green am-playlist-sync job on 10-27/28 died on
/// `GET /v1/me/library/playlists -> 403` that way. So:
///   • the FIRST token of a launch is always minted with `.ignoreCache` (a cached token has never
///     been validated this launch), then memoized for the launch — we don't hammer MusicKit;
///   • after any Apple 401/403 the caller calls `refreshAfterRejection(of:)`, which re-mints with
///     `.ignoreCache` once per rejected token (concurrent callers coalesce onto one mint).
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
            case .notAuthorized:             return "Grant Apple Music access first (Settings ▸ Apple Music ▸ Credentials)."
            case .developerTokenFailed:      return "Couldn’t reach the Apple Music sync service."
            case .userTokenUnavailable(let m): return "Couldn’t get an Apple Music token: \(m)"
            }
        }
    }

    /// App-wide instance: its memo IS the launch-wide "validated fresh token".
    static let shared = MusicUserTokenService()

    /// Injected base (tests); nil ⇒ `Config.amPlaylistSyncBase` read LIVE per request.
    private let baseOverride: URL?
    private var base: URL { baseOverride ?? Config.amPlaylistSyncBase }
    private let session: URLSession
    private let minter: MusicUserTokenMinting
    /// nil ⇒ ready to mint; otherwise the reason we can't (enabled/authorized gates).
    private let preflight: @MainActor () -> TokenError?
    private var cachedDevToken: (token: String, expMs: Double)?
    /// The token minted with `.ignoreCache` this launch (nil until first use / after a rejection).
    private var freshToken: String?
    private var inFlightMint: Task<String, Error>?

    init(base: URL? = nil,
         session: URLSession = .shared,
         minter: MusicUserTokenMinting = MusicKitUserTokenMinter(),
         preflight: (@MainActor () -> TokenError?)? = nil) {
        self.baseOverride = base
        self.session = session
        self.minter = minter
        self.preflight = preflight ?? { MusicUserTokenService.liveReadiness() }
    }

    private static func liveReadiness() -> TokenError? {
        #if canImport(MusicKit)
        guard AppleMusicCredentials.isEnabled else { return .notEnabled }
        guard MusicAuthorization.currentStatus == .authorized else { return .notAuthorized }
        return nil
        #else
        return .notEnabled
        #endif
    }

    /// App-wide developer token from the sync Lambda (`GET /musickit-token`), cached until it has
    /// < 7 days of life. It's app-wide + low-value on its own (useless without a user token).
    func developerToken() async throws -> String {
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let c = cachedDevToken, c.expMs - nowMs > 7 * 24 * 3600 * 1000 { return c.token }
        var req = URLRequest(url: base.appendingPathComponent("musickit-token"))
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let dt = try? JSONDecoder().decode(DeveloperTokenResponse.self, from: data) else {
            throw TokenError.developerTokenFailed
        }
        cachedDevToken = (dt.token, dt.expiresAt)
        return dt.token
    }

    /// The per-user Music-User-Token for web-API/server use: the launch's fresh (`.ignoreCache`)
    /// token, minting it on first use. DEVICE-ONLY — throws on the Simulator, with no active
    /// subscription, or without prior authorization.
    func musicUserToken() async throws -> String {
        if let t = freshToken { return t }
        return try await mintFresh()
    }

    /// Apple rejected `rejected` (401/403): re-mint with `.ignoreCache`. Returns the replacement,
    /// or nil when Apple hands back the SAME token (retrying with it is pointless — the caller
    /// surfaces the original error instead of looping). If another caller already replaced the
    /// rejected token, that replacement is returned without a new mint.
    func refreshAfterRejection(of rejected: String) async throws -> String? {
        if let t = freshToken, t != rejected { return t }
        if inFlightMint == nil { freshToken = nil }
        let t = try await mintFresh()
        return t == rejected ? nil : t
    }

    private func mintFresh() async throws -> String {
        if let task = inFlightMint { return try await task.value }
        if let err = preflight() { throw err }
        let minter = self.minter
        let task = Task<String, Error> { @MainActor in
            let developer = try await self.developerToken()
            do {
                return try await minter.userToken(developerToken: developer, ignoreCache: true)
            } catch {
                throw TokenError.userTokenUnavailable(error.localizedDescription)
            }
        }
        inFlightMint = task
        defer { inFlightMint = nil }
        let t = try await task.value
        freshToken = t
        return t
    }
}
