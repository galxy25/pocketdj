import Foundation

/// The diag-writer secret, lightly obfuscated so the literal doesn't sit in cleartext in
/// the binary's string table (defense against casual `strings` scraping only — the key is
/// ALREADY scoped to PutObject on one expiring log prefix; see DiagLog's header).
enum DiagSecret {
    static var value: String {
        String(bytes: bytes.map { $0 ^ 0x5A }, encoding: .utf8) ?? ""
    }
    // Populated by scripts/gen-diag-secret.sh at setup time; never commit the raw key.
    static let bytes: [UInt8] = DIAG_SECRET_BYTES
}
