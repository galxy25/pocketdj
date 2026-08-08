import Foundation

/// A song EDITION selector (clean vs explicit). Variant song ids ride every songId-keyed
/// system (rips manifest, stems, analysis, burns) as "<baseId>_clean" / "<baseId>_explicit"
/// — e.g. "sng_1a7f6bc854af_clean" — so a clean rip is a DISTINCT S3 object from the
/// user's primary cut. All source song ids are `sng_<12 lowercase hex>` (vinyl, Apple
/// Music (Local), My Digital), so the shape below is unambiguous and can never collide
/// with `amrec_`/`smp_`/`lp_`/`ptn_`/`tk_`/`pdj_` ids.
enum SongVariant: String, Codable, Sendable, CaseIterable {
    case clean, explicit

    /// ("sng_ab…_clean") -> (base: "sng_ab…", variant: .clean); nil for a plain id or
    /// anything not shaped `sng_<12 lowercase hex>_<clean|explicit>`.
    static func parse(fromSongId id: String) -> (base: String, variant: SongVariant)? {
        for v in SongVariant.allCases {
            let suffix = "_" + v.rawValue
            guard id.hasSuffix(suffix) else { continue }
            let base = String(id.dropLast(suffix.count))
            guard base.hasPrefix("sng_") else { return nil }
            let hex = base.dropFirst(4)
            guard hex.count == 12, hex.allSatisfy(isLowerHex) else { return nil }
            return (base, v)
        }
        return nil
    }

    /// The base (catalog) song id behind a possibly-variant id; identity for plain ids.
    static func baseId(_ id: String) -> String { parse(fromSongId: id)?.base ?? id }

    /// Mint the variant songId for a base id + edition.
    static func variantId(_ base: String, _ v: SongVariant) -> String { "\(base)_\(v.rawValue)" }

    /// `[0-9a-f]` only — the id convention is lowercase hex (uppercase would be a
    /// different, unknown id shape and must not parse as a variant).
    private static func isLowerHex(_ c: Character) -> Bool {
        ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c))
    }
}
