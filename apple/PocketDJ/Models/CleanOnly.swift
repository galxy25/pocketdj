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

    /// The substitution itself is `EditionPolicy.decide(collectionCleanOnly: true)` — the ONE
    /// precedence function — so this rule and the global prefer-explicit rule can never drift
    /// apart. What lives HERE is the part that is unique to clean-only: the DROP. A decision
    /// with no `catalogId` means the clean edition is unresolved, which under clean-only is
    /// the "skipped" case (never a fallback to the explicit cut).
    static func resolve(ids: [String], songsById: [String: IndexSong]) -> Resolved {
        var out: [String] = []
        var variants: [String: SongVariant] = [:]
        for id in ids {
            guard let s = songsById[id] else { out.append(id); continue }   // studio/profile/unknown
            if s.explicit != true { out.append(id); continue }
            let d = EditionPolicy.decide(song: s, collectionCleanOnly: true, preferExplicitRaw: nil)
            if let v = d.edition, d.catalogId != nil {
                out.append(id)
                variants[id] = v
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

/// THE edition decision. One function, one place — every surface that plays, stores or
/// acquires audio asks this which EDITION (clean / explicit) of a song it should be dealing
/// with. Nothing else is allowed to reason about the clean-only flag or the explicit-versions
/// preference; scattering that precedence across call sites is exactly how the two play paths
/// (streamed vs. stored file) drifted apart in the first place.
///
/// PRECEDENCE (locked with Levi, in this order):
///   1. the COLLECTION being played carries the clean-only flag → CLEAN wins, always — it
///      beats the global toggle, so a clean-only pocket stays clean even with "Prefer
///      explicit versions" on;
///   2. otherwise the global Settings ▸ Apple Music ▸ "Prefer explicit versions" toggle
///      decides — ON ⇒ EXPLICIT;
///   3. otherwise the song plays exactly what it resolves to today (no substitution).
///
/// A substitution is only ever chosen when the wanted edition's catalog id is BOTH known AND
/// different from the song's primary id. That single rule is what keeps this in lockstep with
/// `AppleMusicProvider.streamCandidates` (the streaming half of the same decision): both
/// substitute under identical conditions, so the stored path and the streamed path can never
/// disagree about which edition is playing. When the primary id ALREADY is the wanted edition
/// (an explicit song under prefer-explicit) the decision is "unchanged" — the base rip IS that
/// edition, and minting a variant id there would only duplicate storage.
///
/// The TRI-STATE preference is honoured as the settings model defines it
/// (`SettingsStore.preferExplicitVersionsRaw`): nil = the user never chose ⇒ NOTHING is
/// substituted (the substitution-default safety gate), false = prefer clean, true = prefer
/// explicit.
enum EditionPolicy {

    /// Which rule produced the decision — it determines the FALLBACK behaviour, which is
    /// deliberately asymmetric (see `allowsStoredFallback`).
    enum Reason: Equatable {
        /// The collection's clean-only flag (rule 1).
        case collectionCleanOnly
        /// The global "Prefer explicit versions" toggle (rule 2).
        case globalPreference
        /// No substitution (rule 3) — play the song's own cut.
        case none
    }

    struct Decision: Equatable {
        /// The edition to play/store/acquire, or nil for "unchanged — the song's own cut".
        var edition: SongVariant?
        var reason: Reason
        /// The catalog id of `edition`, when known. nil ⇒ NEVER enqueue a rip for it (the
        /// acquire path's hard gate: we do not ask the server to capture an edition we
        /// cannot name).
        var catalogId: String?

        /// May playback fall back to a DIFFERENT edition's stored file when the wanted one
        /// is missing?
        ///   • clean-only: NO. The locked `CleanOnly` rule is skip-not-fallback — a
        ///     clean-only collection must never reach for the explicit cut, so a missing
        ///     clean file means skip, not "close enough".
        ///   • the global preference: YES. It is a PREFERENCE, and going silent because the
        ///     explicit rip hasn't landed yet would be worse than hearing the cut we already
        ///     have while the lazy rip fetches the right one.
        var allowsStoredFallback: Bool { reason != .collectionCleanOnly }

        /// Rule 3 — the song plays what it always played.
        static let unchanged = Decision(edition: nil, reason: .none, catalogId: nil)
    }

    /// The decision for one song. `song` nil (a studio / profile / unknown id — they carry no
    /// explicitness) ⇒ unchanged.
    static func decide(song: IndexSong?,
                       collectionCleanOnly: Bool,
                       preferExplicitRaw: Bool?) -> Decision {
        guard let song else { return .unchanged }

        // RULE 1 — the collection's clean-only flag beats everything.
        if collectionCleanOnly {
            // Non-explicit songs pass through untouched (the `CleanOnly` rule: nil =
            // unclassified = treated non-explicit).
            guard song.explicit == true else { return .unchanged }
            return substitution(song, .clean, reason: .collectionCleanOnly)
        }

        // RULE 2 — the global tri-state preference.
        guard let preferExplicit = preferExplicitRaw else { return .unchanged }   // unset ⇒ rule 3
        return substitution(song, preferExplicit ? .explicit : .clean, reason: .globalPreference)
    }

    /// A substitution is REAL only when the edition's catalog id is known and distinct from
    /// the primary; anything else is "unchanged" (see the type doc). Mirrors
    /// `AppleMusicProvider.streamCandidates`'s condition exactly.
    private static func substitution(_ song: IndexSong, _ edition: SongVariant,
                                     reason: Reason) -> Decision {
        guard let id = song.appleMusicId(for: edition), !id.isEmpty else {
            // The wanted edition is UNRESOLVED. Under clean-only that is the "skipped" case —
            // the row is dropped by `CleanOnly.resolve` before it ever plays, and any surface
            // that still asks gets a clean decision with NO id (so nothing is acquired and no
            // explicit fallback is allowed). Under the global preference an unresolved edition
            // simply means "unchanged".
            return reason == .collectionCleanOnly
                ? Decision(edition: edition, reason: reason, catalogId: nil)
                : .unchanged
        }
        guard id != song.appleMusicId else { return .unchanged }   // the primary already IS this edition
        return Decision(edition: edition, reason: reason, catalogId: id)
    }

    // MARK: Storage resolution (clean + explicit side by side)

    /// The ordered STORAGE IDS to look for a song's audio under, given the wanted edition —
    /// the edition-keyed storage scheme and its backward compatibility, in one list:
    ///
    ///   1. `<baseId>_<edition>` — the edition-keyed object (`rips/<baseId>_<edition>.mp3`
    ///      server-side, the same id in the burn index). Clean and explicit therefore coexist
    ///      for one song; neither can overwrite the other.
    ///   2. `<baseId>` — the LEGACY, un-suffixed rip. Every file that existed before editions
    ///      were keyed lives here, its edition unknown. It is never moved, never rewritten and
    ///      never deleted; it simply plays, exactly as it always has.
    ///   3. the OTHER edition — last resort, so a song with only one edition on disk still
    ///      plays instead of going silent.
    ///
    /// Steps 2 and 3 are gated on `allowFallback` (`Decision.allowsStoredFallback`): a
    /// clean-only collection takes step 1 or nothing.
    static func storageIds(base: String, edition: SongVariant?, allowFallback: Bool) -> [String] {
        guard let edition else { return [base] }
        let wanted = SongVariant.variantId(base, edition)
        guard allowFallback else { return [wanted] }
        let other: SongVariant = edition == .explicit ? .clean : .explicit
        return [wanted, base, SongVariant.variantId(base, other)]
    }

    /// Walk `storageIds` and return the first id that IS stored, plus whether that hit is the
    /// edition we actually wanted. `isWanted == false` means playback is degrading gracefully
    /// onto a legacy / other-edition file and the caller should ALSO kick off `lazyRipId`.
    /// nil ⇒ nothing is stored under any of them (stream it, or skip under clean-only).
    static func resolveStored(base: String, decision: Decision,
                              isStored: (String) -> Bool) -> (id: String, isWanted: Bool)? {
        let ids = storageIds(base: base, edition: decision.edition,
                             allowFallback: decision.allowsStoredFallback)
        guard let hit = ids.first(where: isStored) else { return nil }
        return (hit, hit == ids[0])
    }

    /// LAZY RIP ON MISS — the id to enqueue when the wanted edition isn't stored yet, or nil
    /// when nothing should be acquired:
    ///   • no substitution wanted (rule 3), or
    ///   • the wanted edition is already stored, or
    ///   • its CATALOG ID IS UNKNOWN. That last one is a hard gate: an edition we cannot name
    ///     could only be captured by guessing from artist+title, which is exactly how
    ///     wrong-edition audio ends up filed under a right-looking key.
    static func lazyRipId(base: String, decision: Decision, isStored: (String) -> Bool) -> String? {
        guard let edition = decision.edition, decision.catalogId?.isEmpty == false else { return nil }
        let wanted = SongVariant.variantId(base, edition)
        return isStored(wanted) ? nil : wanted
    }
}
