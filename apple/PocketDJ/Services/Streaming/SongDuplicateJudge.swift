import Foundation

/// Decides whether two songs are LIKELY THE SAME RECORDING by name + artist — the gate that
/// stops a sync from adding a duplicate row to a collection on either side (Levi 2026-07-29:
/// "we shouldn't add a new song to a collection on either side … if there is already a song
/// with that same name and artist; we can use on-device LLM to decide").
///
/// TWO TIERS:
///   1. A deterministic NORMALIZED match (casefold, trim, collapse whitespace, strip decorative
///      punctuation) — fast, offline, and TIGHT by doctrine: version markers ("live", "remix",
///      "instrumental", parenthetical remaster tags) are kept, so different cuts never collapse
///      (the prefer-tight-matching lesson: keep the user's specific recording).
///   2. An ON-DEVICE LLM tie-break for borderline pairs (same normalized title, artist strings
///      that differ — "feat." orderings, "&" vs "and", collaborator subsets) via Apple's
///      FoundationModels when the OS/device supports it. Strictly optional: absent/slow/failed
///      LLM ⇒ fall back to "not a duplicate" (adding a maybe-dup is recoverable; silently
///      dropping a genuinely new song is not).
enum SongDuplicateJudge {

    /// Normalization shared by both sides of every comparison. Deliberately does NOT strip
    /// parenthetical content — "(Live)" / "(2011 Remaster)" / "(Instrumental)" must keep two
    /// versions distinct.
    nonisolated static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[’'\"“”\\[\\]{}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One comparable identity key. Songs sharing this key are treated as the same recording.
    nonisolated static func key(name: String, artist: String) -> String {
        normalized(name) + "\u{1}" + normalized(artist)
    }

    /// Tier 1 — the deterministic call. Same normalized title AND artist ⇒ duplicate.
    nonisolated static func isExactDuplicate(name a: String, artist aArtist: String,
                                             name b: String, artist bArtist: String) -> Bool {
        key(name: a, artist: aArtist) == key(name: b, artist: bArtist)
    }

    /// Is this pair worth an LLM opinion? Same title but different artist strings — the
    /// "feat."-ordering / collaborator-subset zone. Anything with different titles is
    /// DIFFERENT, full stop (tight matching).
    nonisolated static func isBorderline(name a: String, artist aArtist: String,
                                         name b: String, artist bArtist: String) -> Bool {
        normalized(a) == normalized(b) && normalized(aArtist) != normalized(bArtist)
    }

    /// The full judgment: exact-normalized ⇒ true; borderline ⇒ ask the on-device model (when
    /// available); otherwise false. Async only for the borderline path.
    static func likelyDuplicate(name a: String, artist aArtist: String,
                                name b: String, artist bArtist: String) async -> Bool {
        if isExactDuplicate(name: a, artist: aArtist, name: b, artist: bArtist) { return true }
        guard isBorderline(name: a, artist: aArtist, name: b, artist: bArtist) else { return false }
        return await llmSaysDuplicate(name: a, artist: aArtist, name2: b, artist2: bArtist) ?? false
    }

    /// Borderline-pair LLM call. nil = unavailable / failed / unparseable ⇒ caller falls back.
    static func llmSaysDuplicate(name: String, artist: String,
                                 name2: String, artist2: String) async -> Bool? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await FoundationModelJudge.sameRecording(name: name, artist: artist,
                                                            name2: name2, artist2: artist2)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The on-device Apple Intelligence tie-break. Isolated in its own availability-gated type so
/// the framework import never leaks into older-OS code paths.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum FoundationModelJudge {
    static func sameRecording(name: String, artist: String,
                              name2: String, artist2: String) async -> Bool? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
            You judge whether two music catalog entries refer to the SAME recording. Different \
            versions (live, remix, instrumental, remaster of a different cut) are NOT the same. \
            Different orderings or subsets of the same collaborating artists ARE the same. \
            Answer with exactly one word: YES or NO.
            """)
        let prompt = """
            Entry A: "\(name)" by \(artist)
            Entry B: "\(name2)" by \(artist2)
            Same recording?
            """
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if answer.hasPrefix("YES") { return true }
        if answer.hasPrefix("NO") { return false }
        return nil
    }
}
#endif
