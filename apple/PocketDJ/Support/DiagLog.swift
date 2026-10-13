import Foundation
import CryptoKit
import Observation
import os

/// Remote diagnostics for TestFlight builds (Levi, 2026-09-02: "add S3 logging into the app
/// so we can debug the Apple TV side quickly"). Buffers small, secret-free event lines and
/// uploads the session log to a PRIVATE S3 prefix so cross-device handshakes (CloudKit sync,
/// credential adoption, catalog loads) can be read from the outside without a tethered Mac.
///
/// SCOPE + SAFETY:
///   • TestFlight/Debug ONLY — gated on the sandbox App Store receipt (App Store builds have
///     a production receipt and never log). No user data: callers log EVENT facts (states,
///     error codes, counts, booleans); never tokens, URLs with credentials, names, or titles.
///   • The writer key is NOT in the binary or in git: the owner enters it in Settings ▸ Debug
///     (Keychain, see `DiagCredentialStore`) and it reaches the owner's other devices via the
///     "diag-key" credsync doc (`DiagKeySync`). It is scoped PutObject-only on the single
///     `diag/*` prefix of a private bucket with 14-day lifecycle expiry.
///   • Never disturbs the app: uploads are off-main and fire-and-forget. But a broken
///     pipeline is NEVER SILENT any more (2026-10-12 — iOS uploads stopped for 5+ days with
///     no signal because a missing key made every call a quiet no-op): `uploadStatus` drives
///     the Settings ▸ Debug readout, each launch writes a `[diag] status` line, upload
///     outcome TRANSITIONS (ok ⇄ failing) are logged as `[diag]` lines, and a missing key is
///     an os_log fault. Lines logged while keyless are BUFFERED (bounded) and uploaded the
///     moment a key arrives — the launch lines survive a credsync adoption later in launch.
///
/// Each launch owns ONE object family — `diag/<platform>-<device8>/<launchStamp>-b<build>.log`
/// plus `…-p2.log`, `…-p3.log`, … as parts rotate — each part rewritten with its full buffer on
/// every flush (idempotent, ordering-proof; readers always see complete files and concatenate
/// the parts). Flushes: buffered ~15 s after the first new line (~3 s in telemetry mode),
/// immediately for `error`-category lines, and on 25+ pending lines. Rotation exists because S3
/// has no append and rewriting one ever-growing object makes upload bytes O(n²) — fine for
/// sparse events, fatal for a telemetry stream.
///
/// TELEMETRY MODE (`telemetry(_:_:)`): every user action + screen presentation, streamed
/// near-live so a CarPlay drive or a TV session can be followed from the bucket. OWNER OPT-IN
/// via Settings ▸ Debug ▸ "Remote telemetry" (pushed here by SettingsStore — the channel gate
/// below still applies, so App Store builds never log). Unlike `log` callers, telemetry lines
/// MAY carry song/screen titles: the owner explicitly chose to stream their own session.
/// Tokens, credentials, and credentialed URLs stay banned everywhere.
@MainActor
@Observable
final class DiagLog {
    static let shared = DiagLog()

    /// Result of one PUT — classified so a 403 (revoked/rotated key) or a transport error is
    /// visible instead of swallowed.
    enum UploadOutcome: Equatable, Sendable {
        case ok
        case http(Int)
        case transport(String)

        var errorText: String? {
            switch self {
            case .ok: return nil
            case .http(let code): return "HTTP \(code)"
            case .transport(let msg): return msg
            }
        }
    }

    typealias Uploader = @Sendable (_ key: String, _ body: Data,
                                    _ credentials: DiagCredentialStore.Credentials) async -> UploadOutcome

    /// What the Settings ▸ Debug readout shows. `lastSuccessAt`/`lastError` persist across
    /// launches (UserDefaults) so a pipeline that died yesterday still reads as dead today.
    struct UploadStatus: Equatable {
        /// Channel gate: TestFlight/Debug (true) vs App Store / test host (false).
        var channelEnabled: Bool
        var keyPresent: Bool
        var lastSuccessAt: Date?
        var lastError: String?
        var lastErrorAt: Date?

        /// The most recent outcome was a failure (an error newer than the last success).
        var failing: Bool {
            guard let errAt = lastErrorAt, lastError != nil else { return false }
            return lastSuccessAt.map { errAt > $0 } ?? true
        }

        var healthy: Bool { channelEnabled && keyPresent && !failing }

        /// One line for the readout and the `[diag] status` log line.
        func summary(now: Date = Date()) -> String {
            guard channelEnabled else { return "off — App Store build (uploads disabled by design)" }
            func ago(_ d: Date?) -> String {
                guard let d else { return "never" }
                let s = max(0, Int(now.timeIntervalSince(d)))
                if s < 120 { return "\(s)s ago" }
                if s < 7_200 { return "\(s / 60)m ago" }
                if s < 172_800 { return "\(s / 3_600)h ago" }
                return "\(s / 86_400)d ago"
            }
            guard keyPresent else { return "DISABLED — no diag key (last ok \(ago(lastSuccessAt)))" }
            if failing { return "FAILING — \(lastError ?? "?") (last ok \(ago(lastSuccessAt)))" }
            return lastSuccessAt == nil ? "ok — no upload yet this install" : "ok — last upload \(ago(lastSuccessAt))"
        }
    }

    private(set) var uploadStatus: UploadStatus

    /// Diag-writer identity (IAM user pocketdj-diag-writer; PutObject on diag/* only), read
    /// from the Keychain. nil ⇒ lines are buffered, nothing uploads. Refreshed by `reloadCredentials()`.
    @ObservationIgnored private var credentials: DiagCredentialStore.Credentials?
    @ObservationIgnored private let store: DiagCredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let uploader: Uploader
    /// The private diag bucket's host, read LIVE from the remote endpoint config (`diagLogsBase`)
    /// so an account move re-points uploads without a release. The writer key must belong to the
    /// same account — it is Keychain/credsync-delivered, never in the binary.
    private static var bucketHost: String {
        Config.diagLogsBase.host ?? EndpointConfig.compiledIn.url(.diagLogsBase).host!
    }
    nonisolated private static let region = "us-west-2"
    private static let osLog = Logger(subsystem: "com.levi.pocketdj", category: "diag")

    private static let lastSuccessKey = "pdj.diag.lastSuccessAt"
    private static let lastErrorKey = "pdj.diag.lastError"
    private static let lastErrorAtKey = "pdj.diag.lastErrorAt"

    /// One cached formatter — a fresh `ISO8601DateFormatter` per line was measurable overhead
    /// at telemetry rates.
    private static let iso = ISO8601DateFormatter()
    /// Seal the current part at this many lines (~≤64 KB a part keeps the rewrite cheap).
    /// Also the cap on lines buffered while no key is configured.
    static let partLineLimit = 500
    /// Hard per-session ceiling (~80 parts): a runaway loop stops costing bytes, with an
    /// explicit final marker line so the truncation is visible in the bucket.
    private static let sessionLineLimit = 40_000

    @ObservationIgnored private var lines: [String] = []
    @ObservationIgnored private var dirty = 0
    @ObservationIgnored private var totalLines = 0
    @ObservationIgnored private var part = 1
    @ObservationIgnored private var keylessOverflowMarked = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// `diag/<platform>-<device8>/<stamp>-b<build>` — the part suffix + ".log" complete it.
    @ObservationIgnored private let keyBase: String
    private var objectKey: String { part == 1 ? keyBase + ".log" : keyBase + "-p\(part).log" }
    @ObservationIgnored private let enabled: Bool

    /// Rich-telemetry mode. Pushed by SettingsStore (launch + toggle) — a stored setting, not
    /// read here, because this singleton can materialize before SettingsStore exists. The
    /// transition is logged so the session file shows exactly when the stream started/stopped.
    @ObservationIgnored var telemetryEnabled = false {
        didSet {
            guard enabled, telemetryEnabled != oldValue else { return }
            log("telemetry", telemetryEnabled ? "mode ON" : "mode OFF")
        }
    }

    private convenience init() {
        #if DEBUG
        let sandbox = true
        #else
        // TestFlight installs carry a sandbox receipt. (The API is deprecated in favour of
        // AppTransaction, but still populated; the readout above makes a gate that wrongly
        // reads "App Store" visible instead of silent.)
        let sandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
        // Fixture runs AND test hosts are excluded: the transport funnels now touch this
        // singleton on every play/skip, and a unit-test process must never PUT to the bucket.
        let enabled = sandbox && ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil
            && NSClassFromString("XCTestCase") == nil
        self.init(enabled: enabled, store: .launchDefault(), defaults: .standard,
                  uploader: { key, body, creds in await DiagLog.put(key: key, body: body, credentials: creds) })
    }

    /// Designated init — injectable so tests drive the real buffering/status logic against a
    /// fake uploader and a test Keychain service.
    init(enabled: Bool, store: DiagCredentialStore, defaults: UserDefaults, uploader: @escaping Uploader) {
        self.enabled = enabled
        self.store = store
        self.defaults = defaults
        self.uploader = uploader
        let creds = enabled ? store.load() : nil
        credentials = creds
        uploadStatus = UploadStatus(
            channelEnabled: enabled, keyPresent: creds != nil,
            lastSuccessAt: defaults.object(forKey: Self.lastSuccessKey) as? Date,
            lastError: defaults.string(forKey: Self.lastErrorKey),
            lastErrorAt: defaults.object(forKey: Self.lastErrorAtKey) as? Date)

        let deviceId: String
        if let existing = defaults.string(forKey: "pdj.diag.deviceId") {
            deviceId = existing
        } else {
            deviceId = String(UUID().uuidString.prefix(8))
            defaults.set(deviceId, forKey: "pdj.diag.deviceId")
        }
        #if os(tvOS)
        let platform = "tvos"
        #elseif os(macOS)
        let platform = "macos"
        #elseif os(visionOS)
        let platform = "visionos"
        #else
        let platform = "ios"
        #endif
        let stamp = Self.iso.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        keyBase = "diag/\(platform)-\(deviceId)/\(stamp)-b\(build)"

        guard enabled else { return }
        log("launch", "build=\(build) platform=\(platform) device=\(deviceId)")
        // Which backend (blue/green AWS account) this launch resolved to, and from where
        // (cached last-good / compiled-in; the async fetch logs its own result line).
        log("endpoints", "launch \(Config.endpoints.summary)")
        log("diag", "status \(statusLine)")
        if creds == nil {
            Self.osLog.fault("diag uploads DISABLED: no diag key in the Keychain (Settings ▸ Debug ▸ Remote diagnostics key)")
        }
    }

    /// `key=present|MISSING last-ok=<iso|never> last-err=<text@iso|none>` — presence facts only.
    private var statusLine: String {
        let s = uploadStatus
        let ok = s.lastSuccessAt.map { Self.iso.string(from: $0) } ?? "never"
        let err = s.lastError.map { e in "\(e)@\(s.lastErrorAt.map { Self.iso.string(from: $0) } ?? "?")" } ?? "none"
        return "key=\(s.keyPresent ? "present" : "MISSING") last-ok=\(ok) last-err=\(err)"
    }

    /// Re-read the Keychain after the key is entered/cleared in Settings ▸ Debug or adopted
    /// via the "diag-key" credsync doc. Gaining a key uploads everything buffered so far.
    func reloadCredentials() {
        guard enabled else { return }
        let had = credentials != nil
        credentials = store.load()
        uploadStatus.keyPresent = credentials != nil
        if !had, credentials != nil {
            log("diag", "key configured; late start — uploading \(lines.count) buffered line(s)")
            flushNow()
        } else if had, credentials == nil {
            log("diag", "key REMOVED — uploads stopped")
            Self.osLog.fault("diag uploads DISABLED: diag key removed")
        }
    }

    /// Append one event line. `category == "error"` flushes immediately. NEVER pass secrets —
    /// log presence/length/codes, not values (titles ride ONLY the `telemetry` lane).
    func log(_ category: String, _ message: String) {
        guard enabled, totalLines < Self.sessionLineLimit else { return }
        let ts = Self.iso.string(from: Date())
        guard credentials != nil else {
            // Keyless: keep a bounded buffer so a key adopted later this session (credsync
            // pull, Settings entry) still ships the launch lines. Never flush.
            if lines.count < Self.partLineLimit - 1 {
                totalLines += 1
                lines.append("\(ts) [\(category)] \(message)")
                dirty += 1
            } else if !keylessOverflowMarked {
                keylessOverflowMarked = true
                lines.append("\(ts) [diag] keyless buffer full — later lines dropped until a key arrives")
                dirty += 1
            }
            return
        }
        totalLines += 1
        if totalLines == Self.sessionLineLimit {
            lines.append("\(ts) [telemetry] session line cap reached — logging muted")
            dirty += 1
            flushNow()
            return
        }
        lines.append("\(ts) [\(category)] \(message)")
        dirty += 1
        if lines.count >= Self.partLineLimit {
            seal()
        } else if category == "error" || dirty >= 25 {
            flushNow()
        } else if flushTask == nil {
            // Telemetry mode shortens the debounce so the bucket trails a live drive by
            // seconds, not a quarter minute.
            let delay: UInt64 = telemetryEnabled ? 3_000_000_000 : 15_000_000_000
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                await MainActor.run { self?.flushNow() }
            }
        }
    }

    /// Rich-telemetry line — user actions and screen presentations. No-op unless the owner's
    /// "Remote telemetry" debug toggle is on (see the header's privacy contract).
    func telemetry(_ category: String, _ message: String) {
        guard telemetryEnabled else { return }
        log(category, message)
    }

    /// Scene-phase hook: backgrounding would strand up to a debounce-window of tail lines
    /// (there is no termination callback worth trusting) — push them out now. Fire-and-forget
    /// like every other flush; iOS grants comfortably enough runway for one small PUT.
    func flushOnBackground() {
        guard enabled, credentials != nil else { return }
        flushNow()
    }

    /// Test seam: wait until every queued upload has completed.
    func waitForUploads() async {
        await uploadChain?.value
    }

    /// Uploads are SERIALIZED through this chain. S3 concurrent PUTs to one key are
    /// last-writer-wins by commit time, and rotation makes the final write to a sealed part
    /// TERMINAL — an in-flight earlier flush landing after the seal's full-body PUT would
    /// permanently truncate that part (the pre-rotation design self-healed because every later
    /// flush rewrote the same key; a sealed part never gets another write). Chaining keeps the
    /// launch order the landing order while every PUT still runs detached off-main.
    @ObservationIgnored private var uploadChain: Task<Void, Never>?
    /// Newest not-yet-uploaded body per key. Every flush of one part is a FULL rewrite, so only
    /// the newest body matters — during a network stall the chain drains ONE PUT per part
    /// instead of a backlog of superseded rewrites (probed: a 200 ms PUT under a 20 ms flush
    /// cadence otherwise queued 88 redundant bodies).
    @ObservationIgnored private var pendingBodies: [String: Data] = [:]

    private func enqueueUpload(key: String, body: Data) {
        let hadPending = pendingBodies[key] != nil
        pendingBodies[key] = body
        guard !hadPending else { return }        // the queued PUT for this key takes the newest
        let prev = uploadChain
        let uploader = self.uploader
        uploadChain = Task { @MainActor [weak self] in
            await prev?.value
            guard let self, let latest = self.pendingBodies.removeValue(forKey: key),
                  let creds = self.credentials else { return }
            let outcome = await Task.detached(priority: .utility) {
                await uploader(key, latest, creds)
            }.value
            self.record(outcome)
        }
    }

    /// Fold one PUT outcome into the status (persisted) and log only TRANSITIONS, so a
    /// failing pipeline can't feed itself an endless stream of `[diag]` lines.
    private func record(_ outcome: UploadOutcome) {
        let wasFailing = uploadStatus.failing
        let firstResult = uploadStatus.lastSuccessAt == nil && uploadStatus.lastErrorAt == nil
        let now = Date()
        if let err = outcome.errorText {
            uploadStatus.lastError = err
            uploadStatus.lastErrorAt = now
            defaults.set(err, forKey: Self.lastErrorKey)
            defaults.set(now, forKey: Self.lastErrorAtKey)
            if !wasFailing || firstResult {
                Self.osLog.error("diag upload FAILED: \(err, privacy: .public)")
                log("diag", "upload FAILED \(err)")
            }
        } else {
            uploadStatus.lastSuccessAt = now
            defaults.set(now, forKey: Self.lastSuccessKey)
            if wasFailing {
                log("diag", "upload recovered (was \(uploadStatus.lastError ?? "?"))")
            }
        }
    }

    private func flushNow() {
        flushTask?.cancel(); flushTask = nil
        guard dirty > 0, credentials != nil else { return }
        dirty = 0
        enqueueUpload(key: objectKey, body: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Final full-buffer upload of the current part, then start the next with a continuity
    /// marker. The seal upload is fire-and-forget like every flush — a lost part costs those
    /// lines, never the app's stability (the design invariant this file exists under).
    private func seal() {
        flushTask?.cancel(); flushTask = nil
        dirty = 0
        enqueueUpload(key: objectKey, body: Data((lines.joined(separator: "\n") + "\n").utf8))
        part += 1
        lines = ["\(Self.iso.string(from: Date())) [rotate] continues in part \(part)"]
        dirty = 1
    }

    // MARK: SigV4 PUT (pure CryptoKit — no SDK)

    nonisolated private static func put(key: String, body: Data,
                                        credentials: DiagCredentialStore.Credentials) async -> UploadOutcome {
        let bucketHost = await MainActor.run { Self.bucketHost }   // one host per request: signed Host == URL host
        let now = Date()
        let amzFmt = DateFormatter()
        amzFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        amzFmt.timeZone = TimeZone(identifier: "UTC")
        amzFmt.locale = Locale(identifier: "en_US_POSIX")
        let amzDate = amzFmt.string(from: now)
        let shortDate = String(amzDate.prefix(8))

        let payloadHash = SHA256.hash(data: body).hex
        // Key segments are [A-Za-z0-9/.-] by construction — safe unencoded in the canonical URI.
        let canonicalURI = "/" + key
        let canonicalHeaders = "host:\(bucketHost)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = "PUT\n\(canonicalURI)\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(shortDate)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n" +
            SHA256.hash(data: Data(canonicalRequest.utf8)).hex

        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let kDate = hmac(Data(("AWS4" + credentials.secret).utf8), shortDate)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, "s3")
        let kSigning = hmac(kService, "aws4_request")
        let signature = hmac(kSigning, stringToSign).hex

        var request = URLRequest(url: URL(string: "https://\(bucketHost)\(canonicalURI)")!)
        request.httpMethod = "PUT"
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) ? .ok : .http(code)
        } catch {
            let ns = error as NSError
            return .transport("\(ns.domain) \(ns.code)")
        }
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
