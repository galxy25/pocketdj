import Foundation

/// Clean-versions-only resolution: the PURE mapping from a collection's resolved ids to
/// the ids/variants that actually play (or rip/burn/stem) when the collection's
/// `cleanOnly` toggle is on. Rule (locked with Levi):
///   • non-explicit songs (`explicit != true`; nil = unclassified = treated non-explicit)
///     pass unchanged;
///   • explicit songs WITH a clean catalog id substitute the CLEAN variant;
///   • explicit songs WITHOUT one are DROPPED (skipped — never a fallback to the
///     explicit cut);
///   • studio/profile/unknown ids pass through untouched (they carry no explicitness).
enum CleanOnly {
    struct Resolved: Equatable {
        /// The surviving ids, in order (base ids — the variant ride is in `variants`).
        var ids: [String]
        /// Base id → the edition that should actually play for it.
        var variants: [String: SongVariant]
    }

    /// Would this song be skipped by a cleanOnly collection? (Explicit with no clean
    /// edition available.) nil song = unknown id = never skipped.
    static func isSkipped(_ song: IndexSong?) -> Bool {
        guard let song, song.explicit == true else { return false }
        return song.appleMusicId(for: .clean) == nil
    }

    static func resolve(ids: [String], songsById: [String: IndexSong]) -> Resolved {
        var out: [String] = []
        var variants: [String: SongVariant] = [:]
        for id in ids {
            guard let s = songsById[id] else { out.append(id); continue }   // studio/profile/unknown
            if s.explicit != true { out.append(id); continue }
            if s.appleMusicId(for: .clean) != nil {
                out.append(id)
                variants[id] = .clean
            }
            // else: dropped (skip — never fall back to the explicit cut)
        }
        return Resolved(ids: out, variants: variants)
    }

    /// Rip/burn/stem id list: same rule, but substituted songs become the VARIANT id
    /// ("<baseId>_clean") so the pipeline captures/keys the clean edition distinctly.
    static func ripIds(ids: [String], songsById: [String: IndexSong]) -> [String] {
        let r = resolve(ids: ids, songsById: songsById)
        var out: [String] = []
        for id in r.ids {
            if let v = r.variants[id] {
                out.append(SongVariant.variantId(id, v))
            } else {
                out.append(id)
            }
        }
        return out
    }
}
