#if DEBUG
import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

/// DEBUG-ONLY test seam (Android QUESTIONS Q25): mint the Apple Music developer token AND this
/// Mac's Music-User-Token and write them to a 0600 file in the app's (sandbox) Application
/// Support folder, so the Android emulator test flow can drive the REAL Apple Music API.
///
/// Double-gated so it can never ship enabled: compiled only in DEBUG (Release/TestFlight/App
/// Store builds don't contain this file's code), and inert unless the launch environment sets
/// `PDJ_DUMP_AM_TOKENS=1`. Tokens are written ONLY to the local file — never logged, never sent
/// to diag logs, never uploaded. The file path (not its contents) is printed to stdout.
///
/// Optional: `PDJ_AM_SYNC_BASE=<https url>` overrides the `/musickit-token` endpoint base.
/// `PDJ_DUMP_AM_TOKENS_EXIT=1` quits the app once the file is written.
///
/// See android/specs/parity/status/Q25-am-tokens.md for the full, repeatable flow.
enum AMTokenDump {
    static let envKey = "PDJ_DUMP_AM_TOKENS"

    static var isRequested: Bool { ProcessInfo.processInfo.environment[envKey] == "1" }

    /// Where the dump lands: `<Application Support>/am-token-dump.json` (inside the sandbox
    /// container on macOS).
    static var outputURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("am-token-dump.json")
    }

    @MainActor static func startIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in await run() }
    }

    @MainActor private static func run() async {
        let env = ProcessInfo.processInfo.environment
        var out: [String: Any] = ["mintedAt": Date().timeIntervalSince1970]
        #if canImport(MusicKit)
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        out["authorization"] = "\(status)"
        let base = env["PDJ_AM_SYNC_BASE"].flatMap(URL.init(string:))
        let service = MusicUserTokenService(base: base)
        do {
            let dev = try await service.developerToken()
            out["developerToken"] = dev
            if status == .authorized {
                do {
                    out["musicUserToken"] = try await MusicUserTokenProvider().userToken(for: dev, options: env["PDJ_DUMP_AM_TOKENS_CACHED"] == "1" ? [] : [.ignoreCache])
                } catch { out["musicUserTokenError"] = "\(error)" }
            } else {
                out["musicUserTokenError"] = "not authorized (\(status))"
            }
        } catch { out["developerTokenError"] = "\(error)" }
        // MusicKit's OWN auto-minted developer token (app-id scoped) + a MUT minted for it — the
        // pair MusicKit itself uses; a fallback when the server-minted pair is rejected.
        if status == .authorized {
            do {
                let auto = try await DefaultMusicTokenProvider().developerToken(options: [])
                out["musicKitDeveloperToken"] = auto
                out["musicKitMusicUserToken"] = try await MusicUserTokenProvider().userToken(for: auto, options: [])
            } catch { out["musicKitTokenError"] = "\(error)" }
            // In-app sanity: does a user-scoped call work through MusicKit itself? (status only)
            if let url = URL(string: "https://api.music.apple.com/v1/me/storefront") {
                do {
                    let r = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
                    out["inAppStorefrontStatus"] = r.urlResponse.statusCode
                } catch { out["inAppStorefrontError"] = "\(error)" }
                // Same call over plain URLSession with the minted pair: tells "token is bad" apart
                // from "MusicKit authenticates differently".
                if let dev = out["developerToken"] as? String, let mut = out["musicUserToken"] as? String {
                    var req = URLRequest(url: url)
                    req.setValue("Bearer \(dev)", forHTTPHeaderField: "Authorization")
                    req.setValue(mut, forHTTPHeaderField: "Music-User-Token")
                    let code = (try? await URLSession.shared.data(for: req))
                        .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                    out["inAppURLSessionStorefrontStatus"] = code ?? -1
                }
            }
        }
        // Optional READ-ONLY end-to-end probe of the real playlist-sync path (GETs only — a PULL
        // job lists library playlists; nothing is written). `PDJ_AM_SYNC_PULL_PROBE=stale` seeds the
        // FIRST mint with MusicKit's cached token, so the 403 → .ignoreCache refresh → retry path
        // runs against the real Apple API.
        if status == .authorized, let mode = env["PDJ_AM_SYNC_PULL_PROBE"] {
            let minter = ProbeMinter(staleFirst: mode == "stale")
            let tokens = MusicUserTokenService(base: base, minter: minter)
            let client = AMPlaylistSyncClient(base: base, tokens: tokens,
                                              defaults: UserDefaults(suiteName: "pdj.amTokenDumpProbe") ?? .standard)
            do {
                let lists = try await client.pull()
                out["syncPullPlaylistCount"] = lists.count
            } catch { out["syncPullError"] = "\(error)" }
            out["syncPullMints"] = minter.log
        }
        #else
        out["error"] = "MusicKit unavailable"
        #endif
        write(out)
        if env["PDJ_DUMP_AM_TOKENS_EXIT"] == "1" { exit(0) }
    }

    #if canImport(MusicKit)
    /// Probe minter: optionally forces the first mint to MusicKit's CACHED token; records each
    /// mint's mode + whether the token changed (never the token itself).
    private final class ProbeMinter: MusicUserTokenMinting, @unchecked Sendable {
        let staleFirst: Bool
        private(set) var log: [String] = []
        private var last: String?
        init(staleFirst: Bool) { self.staleFirst = staleFirst }
        func userToken(developerToken: String, ignoreCache: Bool) async throws -> String {
            let useCache = staleFirst && log.isEmpty
            let t = try await MusicKitUserTokenMinter().userToken(developerToken: developerToken,
                                                                  ignoreCache: ignoreCache && !useCache)
            log.append("\(useCache ? "cached" : "ignoreCache")\(last.map { $0 == t ? ":same" : ":changed" } ?? "")")
            last = t
            return t
        }
    }
    #endif

    private static func write(_ obj: [String: Any]) {
        let url = outputURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let keys = obj.keys.sorted().joined(separator: ",")
            print("[AMTokenDump] wrote \(url.path) keys=\(keys)")
        } catch {
            print("[AMTokenDump] write failed: \(error)")
        }
    }
}
#endif
