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

    // MARK: Same-release tier (Levi 2026-10-19)
    //
    // The exact key misses the commonest real-world twin: ONE track on ONE album indexed twice
    // with its featured credit moved between title and artist ("Never Let Me Down | Kanye West,
    // Jay-Z & J-Ivy" vs "Never Let Me Down (feat. JAŸ-Z & J. Ivy) | Kanye West"), or a respelt
    // artist ("JAY Z" / "JAŸ-Z", "J Kwon" / "J-Kwon"). The album pins the recording, so this tier
    // may loosen title + artist WITHOUT loosening across releases:
    //   • same album (normalized, non-empty) AND same title once feat. credits are stripped;
    //   • at least one shared artist token (primary + feat. credits, punctuation-free);
    //   • NOT when both carry Apple Music catalog ids that differ — those are distinct catalog
    //     recordings ("E.T." vs "E.T. (feat. Kanye West)");
    //   • NOT when both credit features and none overlap — a different version ("Goodies (feat.
    //     Petey Pablo)" vs "Goodies (feat. T.I. & Jazze Pha)").
    // Version markers other than feat. ("Live", "Remix", "Instrumental") stay in the title, so
    // different cuts never collapse (prefer-tight-matching).

    /// The fields the same-release tier compares. `album` is the album NAME (ids differ across
    /// sources for the same release).
    struct Identity: Sendable, Equatable {
        var name: String
        var artist: String
        var album: String?
        var appleMusicId: String?
    }

    private nonisolated static let featInTitle =
        #"\s*[\(\[]\s*(?:feat|ft|featuring|with)\b[^\)\]]*[\)\]]|\s+(?:feat|ft|featuring)\b.*$"#
    private nonisolated static let featCredit =
        #"[\(\[]\s*(?:feat|ft|featuring|with)\b([^\)\]]*)|\s(?:feat|ft|featuring)\b(.*)$"#
    private nonisolated static let artistSeparators =
        #"\s*(?:,|&|\band\b|\bx\b|\bfeat\b|\bft\b|\bfeaturing\b|\bwith\b|/|\+)\s*"#
    private nonisolated static let creditSeparators = #"\s*(?:,|&|\band\b|\bx\b|/|\+)\s*"#

    /// `normalized` minus every character that isn't a letter, digit or space — so "Mr. Carter"
    /// / "Mr Carter" and "What's Going On" / "Whats Going On" agree. Unicode-aware: non-Latin
    /// titles keep their letters (an ASCII-only strip collapsed every Korean title to "").
    nonisolated static func loose(_ s: String) -> String {
        let kept = normalized(s).unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        return String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Title with its feat./ft./featuring/with credit removed (parenthesised, bracketed or
    /// trailing), loosely normalized.
    nonisolated static func baseTitle(_ name: String) -> String {
        loose(name.replacingOccurrences(of: featInTitle, with: "",
                                        options: [.regularExpression, .caseInsensitive]))
    }

    private nonisolated static func tokens(_ s: String, splitBy pattern: String) -> Set<String> {
        let parts = normalized(s)
            .replacingOccurrences(of: pattern, with: "\u{1}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1}")
        return Set(parts.map { String(String.UnicodeScalarView($0.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })) }.filter { !$0.isEmpty })
    }

    /// The feat. credit named in the TITLE, if any.
    private nonisolated static func featCreditText(_ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: featCredit, options: .caseInsensitive),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        for g in 1...2 {
            if let r = Range(m.range(at: g), in: name) { return String(name[r]) }
        }
        return nil
    }

    /// Every credited artist — the artist field plus any feat. credit in the title.
    nonisolated static func artistTokens(name: String, artist: String) -> Set<String> {
        var all = tokens(artist, splitBy: artistSeparators)
        if let credit = featCreditText(name) { all.formUnion(tokens(credit, splitBy: creditSeparators)) }
        return all
    }

    /// The title's feat. credits alone (nil = the title credits nobody).
    nonisolated static func featTokens(name: String) -> Set<String>? {
        featCreditText(name).map { tokens($0, splitBy: creditSeparators) }
    }

    /// Bucket key for the same-release tier; nil = not comparable (no album or empty title).
    nonisolated static func releaseKey(_ s: Identity) -> String? {
        guard let album = s.album.map(loose), !album.isEmpty else { return nil }
        let title = baseTitle(s.name)
        guard !title.isEmpty else { return nil }
        return title + "\u{1}" + album
    }

    /// Tier 1b — the same-release judgment (see the MARK above).
    nonisolated static func isSameReleaseDuplicate(_ a: Identity, _ b: Identity) -> Bool {
        guard let ka = releaseKey(a), ka == releaseKey(b) else { return false }
        if let ia = a.appleMusicId, let ib = b.appleMusicId, !ia.isEmpty, !ib.isEmpty, ia != ib { return false }
        guard !artistTokens(name: a.name, artist: a.artist)
                .isDisjoint(with: artistTokens(name: b.name, artist: b.artist)) else { return false }
        if let fa = featTokens(name: a.name), let fb = featTokens(name: b.name),
           !fa.isEmpty, !fb.isEmpty, fa.isDisjoint(with: fb) { return false }
        return true
    }

    /// Exact OR same-release.
    nonisolated static func isDuplicate(_ a: Identity, _ b: Identity) -> Bool {
        isExactDuplicate(name: a.name, artist: a.artist, name: b.name, artist: b.artist)
            || isSameReleaseDuplicate(a, b)
    }

    /// The running "already have this recording?" set every gate uses — the exact key PLUS
    /// the same-release tier, bucketed by `releaseKey` so it stays O(n) over big playlists.
    struct Seen {
        private var exact = Set<String>()
        private var buckets: [String: [Identity]] = [:]
        nonisolated init() {}
        /// true = new recording (now remembered); false = a duplicate of one already seen.
        nonisolated mutating func insert(_ s: Identity) -> Bool {
            guard exact.insert(SongDuplicateJudge.key(name: s.name, artist: s.artist)).inserted else { return false }
            guard let rk = SongDuplicateJudge.releaseKey(s) else { return true }
            if buckets[rk]?.contains(where: { SongDuplicateJudge.isSameReleaseDuplicate($0, s) }) == true {
                return false
            }
            buckets[rk, default: []].append(s)
            return true
        }
    }

    /// Collapse duplicate recordings in an ordered id list. Each group of twins keeps ONE id
    /// — the first member carrying an Apple Music catalog id (it streams instead of needing a
    /// rip), else the first — and that survivor takes the group's EARLIEST slot.
    /// `rename` maps a group's first id → its survivor (when they differ); `drop` is every
    /// other member. Ids `identity` can't resolve are never touched; a repeated SAME id is a
    /// deliberate repeat, not a twin.
    struct CollapsePlan: Equatable {
        var rename: [String: String] = [:]
        var drop: Set<String> = []
        var isEmpty: Bool { drop.isEmpty }
    }
    nonisolated static func collapsePlan(_ ids: [String], identity: (String) -> Identity?) -> CollapsePlan {
        var groups: [[String]] = []
        var exactGroup: [String: Int] = [:]
        var buckets: [String: [(Identity, Int)]] = [:]   // releaseKey → (group lead identity, group)
        var seenIds = Set<String>()
        var identities: [String: Identity] = [:]
        for id in ids where seenIds.insert(id).inserted {
            guard let s = identity(id) else { continue }
            identities[id] = s
            let ek = key(name: s.name, artist: s.artist)
            let rk = releaseKey(s)
            var g = exactGroup[ek]
            if g == nil, let rk {
                g = buckets[rk]?.first(where: { isSameReleaseDuplicate($0.0, s) })?.1
            }
            if let g {
                groups[g].append(id)
                if exactGroup[ek] == nil { exactGroup[ek] = g }
            } else {
                groups.append([id])
                exactGroup[ek] = groups.count - 1
                if let rk { buckets[rk, default: []].append((s, groups.count - 1)) }
            }
        }
        var plan = CollapsePlan()
        for g in groups where g.count > 1 {
            let survivor = g.first { !(identities[$0]?.appleMusicId ?? "").isEmpty } ?? g[0]
            if survivor != g[0] { plan.rename[g[0]] = survivor }
            plan.drop.formUnion(g.dropFirst())
        }
        return plan
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

extension AppModel {
    /// The same-release identity of a catalog song (nil = not in the live catalog).
    func duplicateIdentity(_ songId: String) -> SongDuplicateJudge.Identity? {
        guard let song = songsById[songId] else { return nil }
        return SongDuplicateJudge.Identity(name: song.name, artist: song.artist,
                                           album: song.albumId.flatMap { albumsById[$0]?.name },
                                           appleMusicId: song.appleMusicId)
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
