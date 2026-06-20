import Foundation
import CryptoKit

struct SigV4Creds: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
}

/// Minimal AWS Signature V4 signer for OpenSearch Serverless ("aoss"), ported
/// from the PWA's `src/search/sigv4.ts`. Native apps have no CORS restriction, so
/// the request goes straight to the aoss collection host (no CloudFront proxy).
enum SigV4 {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ data: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the headers to attach to a signed request. `host` is the value
    /// aoss validates against; `path` is the exact request path (e.g. `/pocketdj/_search`).
    static func sign(method: String, host: String, path: String, body: Data,
                     region: String, service: String, creds: SigV4Creds,
                     date: Date = Date()) -> [String: String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = fmt.string(from: date)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = sha256Hex(body)

        let canonicalHeaders = "host:\(host)\n"
            + "x-amz-content-sha256:\(payloadHash)\n"
            + "x-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        // path segments here are already URL-safe (/pocketdj/_search).
        let canonicalRequest = [method, path, "", canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")

        let kDate = hmac(Data("AWS4\(creds.secretAccessKey)".utf8), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        let kSigning = hmac(kService, "aws4_request")
        let signature = hex(hmac(kSigning, stringToSign))

        return [
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
            "Content-Type": "application/json",
            "Authorization": "AWS4-HMAC-SHA256 "
                + "Credential=\(creds.accessKeyId)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
        ]
    }
}
