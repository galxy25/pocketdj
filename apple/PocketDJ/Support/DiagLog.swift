import Foundation
import CryptoKit

/// Remote diagnostics for TestFlight builds (Levi, 2026-09-02: "add S3 logging into the app
/// so we can debug the Apple TV side quickly"). Buffers small, secret-free event lines and
/// uploads the session log to a PRIVATE S3 prefix so cross-device handshakes (CloudKit sync,
/// credential adoption, catalog loads) can be read from the outside without a tethered Mac.
///
/// SCOPE + SAFETY:
///   • TestFlight/Debug ONLY — gated on the sandbox App Store receipt (App Store builds have
///     a production receipt and never log). No user data: callers log EVENT facts (states,
///     error codes, counts, booleans); never tokens, URLs with credentials, names, or titles.
///   • The embedded key is a DELIBERATE scoped tradeoff (the `recEngineEnrollSecret`
///     precedent): PutObject-only, single `diag/*` prefix, private bucket, 14-day lifecycle
///     expiry. Worst-case extraction = someone can write expiring text files to a log prefix.
///   • Fire-and-forget: upload failures are swallowed — diagnostics must never disturb the
///     app, and a device that can't reach S3 simply reports nothing.
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
final class DiagLog {
    static let shared = DiagLog()

    // Scoped diag-writer identity (IAM user pocketdj-diag-writer; PutObject on diag/* only).
    private static let accessKey = "REDACTED_ACCESS_KEY_ID"
    private static let secretKey = DiagSecret.value
    private static let bucketHost = "pocketdj-logs-011183829623.s3.us-west-2.amazonaws.com"
    private static let region = "us-west-2"

    /// One cached formatter — a fresh `ISO8601DateFormatter` per line was measurable overhead
    /// at telemetry rates.
    private static let iso = ISO8601DateFormatter()
    /// Seal the current part at this many lines (~≤64 KB a part keeps the rewrite cheap).
    private static let partLineLimit = 500
    /// Hard per-session ceiling (~80 parts): a runaway loop stops costing bytes, with an
    /// explicit final marker line so the truncation is visible in the bucket.
    private static let sessionLineLimit = 40_000

    private var lines: [String] = []
    private var dirty = 0
    private var totalLines = 0
    private var part = 1
    private var flushTask: Task<Void, Never>?
    /// `diag/<platform>-<device8>/<stamp>-b<build>` — the part suffix + ".log" complete it.
    private let keyBase: String
    private var objectKey: String { part == 1 ? keyBase + ".log" : keyBase + "-p\(part).log" }
    private let enabled: Bool

    /// Rich-telemetry mode. Pushed by SettingsStore (launch + toggle) — a stored setting, not
    /// read here, because this singleton can materialize before SettingsStore exists. The
    /// transition is logged so the session file shows exactly when the stream started/stopped.
    var telemetryEnabled = false {
        didSet {
            guard enabled, telemetryEnabled != oldValue else { return }
            log("telemetry", telemetryEnabled ? "mode ON" : "mode OFF")
        }
    }

    private init() {
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
        // Fixture runs AND test hosts are excluded: the transport funnels now touch this
        // singleton on every play/skip, and a unit-test process must never PUT to the bucket.
        enabled = sandbox && ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil
            && NSClassFromString("XCTestCase") == nil

        let defaults = UserDefaults.standard
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

        if enabled {
            log("launch", "build=\(build) platform=\(platform) device=\(deviceId)")
        }
    }

    /// Append one event line. `category == "error"` flushes immediately. NEVER pass secrets —
    /// log presence/length/codes, not values (titles ride ONLY the `telemetry` lane).
    func log(_ category: String, _ message: String) {
        guard enabled, totalLines < Self.sessionLineLimit else { return }
        totalLines += 1
        let ts = Self.iso.string(from: Date())
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
        guard enabled else { return }
        flushNow()
    }

    /// Uploads are SERIALIZED through this chain. S3 concurrent PUTs to one key are
    /// last-writer-wins by commit time, and rotation makes the final write to a sealed part
    /// TERMINAL — an in-flight earlier flush landing after the seal's full-body PUT would
    /// permanently truncate that part (the pre-rotation design self-healed because every later
    /// flush rewrote the same key; a sealed part never gets another write). Chaining keeps the
    /// launch order the landing order while every PUT still runs detached off-main.
    private var uploadChain: Task<Void, Never>?
    /// Newest not-yet-uploaded body per key. Every flush of one part is a FULL rewrite, so only
    /// the newest body matters — during a network stall the chain drains ONE PUT per part
    /// instead of a backlog of superseded rewrites (probed: a 200 ms PUT under a 20 ms flush
    /// cadence otherwise queued 88 redundant bodies).
    private var pendingBodies: [String: Data] = [:]

    private func enqueueUpload(key: String, body: Data) {
        let hadPending = pendingBodies[key] != nil
        pendingBodies[key] = body
        guard !hadPending else { return }        // the queued PUT for this key takes the newest
        let prev = uploadChain
        uploadChain = Task { @MainActor [weak self] in
            await prev?.value
            guard let latest = self?.pendingBodies.removeValue(forKey: key) else { return }
            await Task.detached(priority: .utility) { await Self.put(key: key, body: latest) }.value
        }
    }

    private func flushNow() {
        flushTask?.cancel(); flushTask = nil
        guard dirty > 0 else { return }
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

    private static func put(key: String, body: Data) async {
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
        let kDate = hmac(Data(("AWS4" + secretKey).utf8), shortDate)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, "s3")
        let kSigning = hmac(kService, "aws4_request")
        let signature = hmac(kSigning, stringToSign).hex

        var request = URLRequest(url: URL(string: "https://\(bucketHost)\(canonicalURI)")!)
        request.httpMethod = "PUT"
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)   // fire-and-forget
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
