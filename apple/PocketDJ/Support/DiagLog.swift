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
/// Each launch owns ONE object — `diag/<platform>-<device8>/<launchStamp>.log` — rewritten
/// with the full cumulative buffer on every flush (idempotent, ordering-proof; readers always
/// see a complete file). Flushes: buffered ~15 s after the first new line, immediately for
/// `error`-category lines, and on 25+ pending lines.
@MainActor
final class DiagLog {
    static let shared = DiagLog()

    // Scoped diag-writer identity (IAM user pocketdj-diag-writer; PutObject on diag/* only).
    private static let accessKey = "REDACTED_ACCESS_KEY_ID"
    private static let secretKey = DiagSecret.value
    private static let bucketHost = "pocketdj-logs-011183829623.s3.us-west-2.amazonaws.com"
    private static let region = "us-west-2"

    private var lines: [String] = []
    private var dirty = 0
    private var flushTask: Task<Void, Never>?
    private let objectKey: String
    private let enabled: Bool

    private init() {
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
        enabled = sandbox && ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil

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
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        objectKey = "diag/\(platform)-\(deviceId)/\(stamp)-b\(build).log"

        if enabled {
            log("launch", "build=\(build) platform=\(platform) device=\(deviceId)")
        }
    }

    /// Append one event line. `category == "error"` flushes immediately. NEVER pass secrets —
    /// log presence/length/codes, not values.
    func log(_ category: String, _ message: String) {
        guard enabled else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        lines.append("\(ts) [\(category)] \(message)")
        dirty += 1
        if category == "error" || dirty >= 25 {
            flushNow()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run { self?.flushNow() }
            }
        }
    }

    private func flushNow() {
        flushTask?.cancel(); flushTask = nil
        guard dirty > 0 else { return }
        dirty = 0
        let body = Data((lines.joined(separator: "\n") + "\n").utf8)
        let key = objectKey
        Task.detached(priority: .utility) {
            await Self.put(key: key, body: body)
        }
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
