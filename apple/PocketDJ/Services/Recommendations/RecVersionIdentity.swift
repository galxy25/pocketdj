import Foundation

/// **IS THIS A DIFFERENT VERSION OF SOMETHING HE ALREADY HAS?**
///
/// Owner, verbatim: *"for collection and new recommendations don't recommend albums and songs we
/// already have but that are a different version (e.g. deluxe or bonus album version, remixes or
/// extended versions)."*
///
/// ── WHY `RecMembership` COULD NOT ANSWER THIS ────────────────────────────────────────────────
/// `RecMembership` asks the IDENTITY question — is this literally the same row, under any of the
/// three ids one recording wears here. It answers *no* for "Rumours (Deluxe Edition)" against
/// "Rumours", and it is right to: those are two different catalog objects with two different store
/// ids. This asks the ADJACENT question — is this the same *record*, wearing a different edition
/// label — which no id comparison can reach because the two sides genuinely have nothing in common
/// but their text.
///
/// ── THE DOCTRINE IS ALREADY WRITTEN, IN `scripts/lib/am-match.mjs` ───────────────────────────
/// That module's `comparableTitle` is this repo's ONE answer to "do two titles name the same
/// recording": a parenthetical is COSMETIC (remaster / deluxe / expanded / bonus / mono / explicit
/// / a bare "LP Version" label / a pure `feat.` credit) or it is RECORDING-ALTERING (mix, remix,
/// edit, radio, single, extended, club, dub, live, acoustic, instrumental, demo, …). This type is
/// that classifier ported to Swift — same word lists, same `original mix` special case, same
/// treatment of credits — because a THIRD title matcher in this app is how the answers start
/// disagreeing. It is a port and not a call because am-match is Node and runs in the indexer.
///
/// ── WHAT THIS ADDS ON TOP, AND WHY IT IS A DIFFERENT QUESTION ────────────────────────────────
/// am-match asks *"are these the same recording?"* and answers NO for a remix — deliberately, so a
/// rip captures the owner's exact cut. Feature 6 asks *"is this a different EDITION OR REWORKING
/// of something he already has?"*, for which a remix answers YES. So the classifier is split one
/// level finer than am-match needs:
///
///   · `.cosmetic`   — Deluxe · Bonus Track Version · Expanded · Remastered · 10th Anniversary.
///                     The SAME record with a different sticker on it. Suppress.
///   · `.derivative` — Extended Mix · Radio Edit · Club Mix · a named Remix · 12" · Single.
///                     A REWORKING of a recording he has. The owner named these explicitly
///                     ("remixes or extended versions"), so: suppress.
///   · `.distinct`   — Live · Acoustic · Unplugged · Instrumental · Demo · Session · Karaoke ·
///                     a cover — AND ANY GROUP THIS FILE DOES NOT RECOGNISE. A genuinely
///                     different performance, which is legitimately new music. NEVER suppressed,
///                     in either direction.
///
/// The unknown-⇒-`.distinct` fallback is the safety property that makes this shippable: a marker
/// nobody anticipated ("(Rick Rubin Sessions)", "(Taylor's Version)") fails OPEN and the row is
/// still offered. Over-suppression silently deletes music from the feed and leaves no trace;
/// under-suppression shows a row he can thumb down. Those failures are not symmetric.
///
/// ── THE GUARD: NEVER ON ARTIST + TITLE ALONE ─────────────────────────────────────────────────
/// Equal artist and equal base title is NOT sufficient and is deliberately NOT suppressed here.
/// The two sides must actually DIFFER BY VERSION MATERIAL (`signature`) — one carries an edition
/// or reworking label the other does not. Plain "same artist, same title, no markers" is either
/// the identical recording (already `RecMembership`'s job, by id) or two songs that merely share a
/// name ("Intro", "Interlude", a reprise on a later record), and killing those on text alone is
/// exactly the over-reach the owner's "different VERSION" wording rules out.
enum RecVersionIdentity {

    // ========================================================================
    // MARK: - The classification
    // ========================================================================

    /// What kind of version material a title carries. Ordered by how much it licenses: only
    /// `.distinct` BLOCKS suppression; the other three permit it.
    enum VersionClass: Int, Sendable, Hashable {
        /// No version material at all — the plain title.
        case standard
        /// Edition/packaging labels only: Deluxe, Bonus Track Version, Expanded, Remastered.
        case cosmetic
        /// A reworking of the recording: Extended Mix, Radio Edit, Club Mix, a named Remix.
        case derivative
        /// A different PERFORMANCE (live/acoustic/instrumental/demo/…) or anything unrecognised.
        /// Never suppressed and never suppresses.
        case distinct
    }

    /// One side of the comparison, pre-computed.
    ///
    /// Pre-computed because the collection pass sweeps ~96k catalog rows ONCE PER COLLECTION: a
    /// classifier called inside that loop would be ~4M parses per refresh. It is derived once per
    /// refresh by `ZoneEngine.versionKeys` (off the main actor) and once per collection by the
    /// memoized `RecMembership`, so the ranking loop does one dictionary lookup and one compare.
    struct Key: Hashable, Sendable {
        /// `normArtist` — the loose artist key (see `artistKey`).
        let artistKey: String
        /// The title with ALL version material removed. "Rumours (Deluxe Edition)" ⇒ `rumours`.
        let base: String
        /// The version material itself, normalized and order-independent. "" for a plain title.
        /// THIS is what makes two entries different VERSIONS rather than the same one.
        let signature: String
        let klass: VersionClass

        /// The bucket both sides must land in before they are even compared.
        var bucket: String { artistKey + "\u{1}" + base }
        /// A different performance — never suppressed, and never grounds to suppress.
        var isDistinct: Bool { klass == .distinct }
        /// Enough to compare at all. An untitled or artist-less row simply does not participate.
        var isUsable: Bool { !artistKey.isEmpty && !base.isEmpty }
    }

    /// Parse a title + artist into its comparable identity. `nil` when there is nothing to compare.
    static func key(title: String, artist: String) -> Key? {
        key(title: title, artistKey: artistKey(artist))
    }

    /// The same, for a caller that has ALREADY normalized the artist. `ZoneEngine.versionKeys`
    /// memoizes that half across a catalog sweep — 96k songs share 12.7k artists — and this is the
    /// entry point that lets it.
    static func key(title: String, artistKey ak: String) -> Key? {
        guard !ak.isEmpty else { return nil }
        let parsed = parse(title)
        guard !parsed.base.isEmpty else { return nil }
        return Key(artistKey: ak, base: parsed.base, signature: parsed.signature, klass: parsed.klass)
    }

    /// **THE PREDICATE.** Is `candidate` a different version of something already owned (`owned`)?
    ///
    /// All four conditions are required, and each one is load-bearing:
    ///   1. the artists agree — a remix released under the REMIXER's own name is a different
    ///      artist's record and stays;
    ///   2. the base titles agree — this is the recording relationship, in the same shape
    ///      am-match's `exact` key uses (normalized artist + comparable title);
    ///   3. neither side is a `.distinct` performance — a live cut is new music, both when it is
    ///      the candidate and when it is the thing already owned;
    ///   4. the version material DIFFERS — the "never on artist+title alone" guard.
    static func supersedes(candidate: Key, owned: Key) -> Bool {
        guard candidate.isUsable, owned.isUsable else { return false }
        guard candidate.artistKey == owned.artistKey, candidate.base == owned.base else { return false }
        guard !candidate.isDistinct, !owned.isDistinct else { return false }
        return candidate.signature != owned.signature
    }

    /// String convenience — the same predicate for callers holding raw text (the tests, and the
    /// release feed, which never sees a catalog row).
    static func isDifferentVersion(candidateTitle: String, candidateArtist: String,
                                   ownedTitle: String, ownedArtist: String) -> Bool {
        guard let c = key(title: candidateTitle, artist: candidateArtist),
              let o = key(title: ownedTitle, artist: ownedArtist) else { return false }
        return supersedes(candidate: c, owned: o)
    }

    /// The same identity with the base's WORD BOUNDARIES removed — `pop star` ⇒ `popstar`.
    /// `nil` when the base has no spaces, so a caller can skip a lookup that would be identical.
    ///
    /// ── WHY THIS EXISTS (a real row, not a hypothetical) ─────────────────────────────────────
    /// Tinashe's pre-order is written `Popstar` in the owner's Library.xml and was reported off
    /// the New screen as "Pop Star". One of Apple's own two spellings of one record is what the
    /// library stored and the other is what the feed showed, and `tokens` splits them into
    /// different bases, so the record read as two.
    ///
    /// Used ONLY by the OWNERSHIP relation (`RecVersionIndex.hasRecord`), never by `supersedes`:
    /// widening feature 6's bucket would change which rows it calls "a different version", which
    /// is a separate question with its own settled answer. Safe to be this loose here because the
    /// artist must already match and the letter sequence must be identical — two DIFFERENT albums
    /// by one artist whose titles differ only in spacing is not a thing that happens.
    static func spacelessKey(_ k: Key) -> Key? {
        let squashed = k.base.replacingOccurrences(of: " ", with: "")
        guard squashed != k.base, !squashed.isEmpty else { return nil }
        return Key(artistKey: k.artistKey, base: squashed, signature: k.signature, klass: k.klass)
    }

    // ========================================================================
    // MARK: - Normalization (ported from am-match.mjs)
    // ========================================================================

    /// `normArtist` — diacritic-folded, lowercased, `&`⇒`and`, parenthetical and `feat.` tails
    /// dropped, punctuation collapsed, leading "the" removed.
    ///
    /// NOT `IndexArtist.normalize`: that is the index's JOIN key and its doc requires it to stay
    /// byte-identical to the Node backfills, so it may not be loosened. It also is not loose
    /// enough here — it would read "Sade" and "Sade (feat. Sweetback)" as two artists and let a
    /// deluxe edition through on a credit difference.
    static func artistKey(_ raw: String) -> String {
        var s = fold(raw)
        s = stripParenGroups(s)
        s = stripCreditTail(s)
        let t = tokens(s).joined(separator: " ")
        if t.hasPrefix("the "), t.count > 4 { return String(t.dropFirst(4)) }
        return t
    }

    /// The whole parse, in one pass over the title.
    static func parse(_ rawTitle: String) -> (base: String, signature: String, klass: VersionClass) {
        let folded = fold(rawTitle)
        var outer = ""
        var groups: [String] = []
        var depth = 0
        var current = ""
        for ch in folded {
            if ch == "(" || ch == "[" || ch == "{" {
                if depth == 0 { current = "" } else { current.append(ch) }
                depth += 1
                continue
            }
            if ch == ")" || ch == "]" || ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0 { groups.append(current); current = "" } else { current.append(ch) }
                } // an unbalanced closer is just punctuation
                continue
            }
            if depth > 0 { current.append(ch) } else { outer.append(ch) }
        }
        // An unterminated group ("Song (Extended Mix") is still version material — a truncated or
        // sloppy title must not silently become part of the base.
        if depth > 0, !current.isEmpty { groups.append(current) }

        // The DASH SUFFIX. Apple Music writes a great deal of version material after " - "
        // rather than in parentheses ("Song - Radio Edit", "Album - Single", "Song - 2011
        // Remaster"), and a feature that only reads parentheses would miss most of the New feed.
        //
        // Taken ONLY when every token of the tail is a word this file recognises. That is the
        // whole safety of it: "Song - Part Two" and "Song - Live at Wembley" contain tokens with
        // no classification, so they stay in the BASE and the row is never suppressed on them.
        if let (head, tail) = splitDashSuffix(outer), isFullyClassified(tail) {
            outer = head
            groups.append(tail)
        }

        outer = stripCreditTail(outer)
        let base = tokens(outer).joined(separator: " ")

        var klass = VersionClass.standard
        var sigTokens: [String] = []
        for g in groups {
            let toks = tokens(g)
            guard !toks.isEmpty else { continue }
            let c = classify(toks)
            guard let c else { continue }   // a pure credit group: not version material at all
            sigTokens.append(contentsOf: toks)
            // The strongest class wins, and `.distinct` is strongest on purpose: "(Live Extended
            // Mix)" keeps the row.
            if c.rawValue > klass.rawValue { klass = c }
        }
        // ORDER-INDEPENDENT: "(Deluxe Edition) (Remastered)" and "(Remastered) (Deluxe Edition)"
        // are one edition, not two.
        let signature = sigTokens.sorted().joined(separator: " ")
        if signature.isEmpty { klass = .standard }
        return (base, signature, klass)
    }

    // ========================================================================
    // MARK: - Word lists
    // ========================================================================

    /// Packaging / provenance labels. A group made only of these (plus numerals) is the SAME
    /// record with a different sticker. Superset of am-match's `COSMETIC_WORDS`, extended with the
    /// edition vocabulary the release feed actually returns.
    private static let cosmetic: Set<String> = [
        // am-match, verbatim
        "remaster", "remastered", "remasters", "deluxe", "expanded", "anniversary",
        "edition", "bonus", "track", "mono", "stereo", "explicit", "clean", "original",
        "lp", "album", "version",
        "and", "the", "a", "an", "of", "feat", "featuring", "ft", "with",
        // format labels: "- EP", "- Single" as a RELEASE KIND, disc/box/vinyl reissues
        "ep", "cd", "disc", "disk", "vinyl", "box", "set", "reissue", "release", "released",
        // edition adjectives Apple ships constantly
        "super", "ultimate", "complete", "special", "limited", "collectors", "collector",
        "standard", "extra", "plus", "digital", "digitally", "tracks", "editions",
        "japanese", "japan", "uk", "us", "usa", "international", "worldwide", "tour",
        "definitive", "essential", "legacy", "platinum", "gold", "silver",
    ]

    /// A REWORKING of a recording. Owner named remixes and extended versions explicitly.
    /// am-match's recording-altering list, minus the performance words below.
    private static let derivative: Set<String> = [
        "mix", "mixes", "mixed", "remix", "remixes", "remixed", "remixer",
        "edit", "edits", "edited", "extended", "radio", "single", "singles",
        "club", "dub", "inch", "rework", "reworked", "refix", "vip", "bootleg",
        "sped", "slowed", "reverb", "nightcore", "megamix", "mashup",
    ]

    /// A different PERFORMANCE. Legitimately new music even when the underlying song is owned,
    /// so it is never suppressed and never suppresses.
    private static let distinct: Set<String> = [
        "live", "acoustic", "unplugged", "session", "sessions", "take", "takes",
        "demo", "demos", "rehearsal", "soundcheck", "concert",
        "instrumental", "instrumentals", "acapella", "acappella", "cappella",
        "karaoke", "cover", "covers", "reprise", "interlude", "skit",
        "orchestral", "symphonic", "choir", "remake", "rerecorded", "rerecording",
    ]

    private static let creditWords: Set<String> = ["feat", "featuring", "ft", "with"]

    /// **WHICH PIECE OF A SET** — not which edition of it.
    ///
    /// FOUND BY RUNNING THIS CLASSIFIER OVER THE REAL 96k-row catalog, which is the only reason it
    /// is here: `Ultimate Aaliyah [Disc 1]` and `Ultimate Aaliyah [Disc 2]` reduced to one bucket
    /// of two "editions", so owning disc 1 would have suppressed disc 2 — an hour of different
    /// music, deleted from the feed with no trace. `disc`/`cd`/`box`/`set` have to stay cosmetic
    /// for the unnumbered cases ("(CD Edition)"), so the discriminator is the NUMBER beside them.
    private static let partDesignators: Set<String> = [
        "disc", "disk", "cd", "volume", "vol", "part", "pt", "side", "chapter", "act",
    ]

    /// Classify one paren/bracket group's tokens. `nil` ⇒ it is a pure CREDIT and carries no
    /// version information at all (am-match's rule: "(feat. Chris Brown)" is not a version).
    private static func classify(_ toks: [String]) -> VersionClass? {
        // "original mix" / "original version" / "original recording" == the standard recording.
        // am-match special-cases this, and it must stay special-cased or every house record with
        // an "(Original Mix)" suffix reads as a reworking of itself.
        let joined = toks.joined(separator: " ")
        if joined == "original mix" || joined == "original version" || joined == "original recording" {
            return .cosmetic
        }
        // A group that STARTS with a credit marker is a credit, whatever follows it.
        if let first = toks.first, creditWords.contains(first) { return nil }
        // A credit marker further in ("Extended Mix feat. X") — judge only what precedes it.
        var head = toks
        if let idx = toks.firstIndex(where: { creditWords.contains($0) }) {
            head = Array(toks[..<idx])
            if head.isEmpty { return nil }
        }
        // "Disc 2", "Vol. 3", "Part Two" — a PIECE of a set, which is different music, not a
        // different edition. Requires the number: "(CD Edition)" stays cosmetic.
        if head.contains(where: { partDesignators.contains($0) }),
           head.contains(where: { isNumeric($0) || romanOrWordNumber($0) }) {
            return .distinct
        }
        if head.contains(where: { distinct.contains($0) }) { return .distinct }
        if head.contains(where: { derivative.contains($0) }) { return .derivative }
        if head.allSatisfy({ cosmetic.contains($0) || isNumeric($0) }) { return .cosmetic }
        // UNRECOGNISED ⇒ treat as a different performance and keep the row. See the type doc:
        // over-suppression is invisible, under-suppression is one thumbs-down.
        return .distinct
    }

    /// Every token classified? The gate on taking a dash suffix as version material.
    private static func isFullyClassified(_ text: String) -> Bool {
        let toks = tokens(text)
        guard !toks.isEmpty else { return false }
        return toks.allSatisfy {
            cosmetic.contains($0) || derivative.contains($0) || distinct.contains($0)
                || creditWords.contains($0) || isNumeric($0)
        }
    }

    // ========================================================================
    // MARK: - Text plumbing
    // ========================================================================

    /// Diacritic-folded, lowercased, `&` ⇒ `and`, `7"`/`12"`/`7-inch` ⇒ `inch` (am-match collapses
    /// these before punctuation is stripped, or the marker is lost).
    ///
    /// ── EVERY BRANCH HERE IS A MEASURED COST, NOT A GUESS ────────────────────────────────────
    /// This runs twice per catalog row when the For You projection is built — ~192k calls on the
    /// owner's library, ON THE MAIN ACTOR. The naive version (`folding` + two unconditional
    /// `replacingOccurrences`, one of them a regex) measured **1.12 s** for that sweep, which is a
    /// visible hang and precisely the class of bug this app has already had to fix once.
    ///
    ///  · `folding(options:)` is a locale-aware ICU call and is the bulk of it. The overwhelming
    ///    majority of titles are pure ASCII, where "fold diacritics and casefold" is just
    ///    `A-Z ⇒ a-z`; the ICU path is kept for the rest, so nothing is lost but the time.
    ///  · `&` and the inch regex are gated behind a `contains`, because they apply to a few
    ///    hundred rows out of 96k and compiling a regex for the other 95,700 is pure waste.
    /// Measured after: **0.39 s** for the same sweep.
    private static func fold(_ s: String) -> String {
        var isASCII = true
        for b in s.utf8 where b >= 128 { isASCII = false; break }
        var t: String
        if isASCII {
            t = String(decoding: s.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
        } else {
            t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        }
        if t.utf8.contains(38) { t = t.replacingOccurrences(of: "&", with: " and ") }
        if t.utf8.contains(34) || t.contains("''") || t.contains("inch") {
            t = t.replacingOccurrences(of: #"\b(7|12)\s*(?:"|''|-?\s*inch)"#, with: " inch ",
                                       options: .regularExpression)
        }
        return t
    }

    /// Split on the LAST " - ". nil when there is none.
    private static func splitDashSuffix(_ s: String) -> (head: String, tail: String)? {
        guard let r = s.range(of: " - ", options: .backwards) else { return nil }
        let head = String(s[s.startIndex..<r.lowerBound])
        let tail = String(s[r.upperBound...])
        guard !head.trimmingCharacters(in: .whitespaces).isEmpty,
              !tail.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (head, tail)
    }

    private static func stripParenGroups(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "(" || ch == "[" || ch == "{" { depth += 1; continue }
            if ch == ")" || ch == "]" || ch == "}" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    /// Drop an un-parenthesized trailing credit ("Song feat. X"). Cosmetic, per am-match.
    private static func stripCreditTail(_ s: String) -> String {
        let toks = tokens(s)
        guard let idx = toks.firstIndex(where: { creditWords.contains($0) && $0 != "with" }) else {
            return s
        }
        // Never let the credit marker eat the whole title ("Featuring" as a song name).
        guard idx > 0 else { return s }
        return toks[..<idx].joined(separator: " ")
    }

    /// Alphanumeric tokens, in order. Everything else is a separator.
    ///
    /// Scans UNICODE SCALARS, not `Character`s: grapheme-cluster breaking is the second-largest
    /// cost in this file after `folding`, and nothing here needs it — a token boundary is a
    /// scalar-level property. ASCII is decided arithmetically and only the rest asks ICU.
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for v in s.unicodeScalars {
            if isWordScalar(v) { cur.append(v) }
            else if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    @inline(__always)
    private static func isWordScalar(_ v: Unicode.Scalar) -> Bool {
        let x = v.value
        if x < 128 { return (x >= 97 && x <= 122) || (x >= 48 && x <= 57) || (x >= 65 && x <= 90) }
        return v.properties.isAlphabetic || v.properties.numericType != nil
    }

    /// A year, a disc number, an ordinal ("35th Anniversary", "1st") — all packaging noise.
    /// Written as digits-then-optional-ordinal rather than "first char is a digit", which read
    /// "35th" as unclassified and quietly let every anniversary edition through.
    private static func isNumeric(_ t: String) -> Bool {
        let digits = t.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let rest = String(t.dropFirst(digits.count))
        return rest.isEmpty || ["st", "nd", "rd", "th"].contains(rest)
    }

    /// "Disc II" / "Part Two" — the same part designator written out. Only consulted beside a
    /// `partDesignators` word, so the short roman numerals cannot misfire on ordinary words.
    private static func romanOrWordNumber(_ t: String) -> Bool {
        switch t {
        case "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
             "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten":
            return true
        default:
            return false
        }
    }
}

// ============================================================================
// MARK: - The owned index
// ============================================================================

/// **WHAT HE ALREADY HAS, IN VERSION SPACE** — the set a candidate is checked against.
///
/// A value type for the same reason `RecMembership` is one: the collection ranking runs
/// `Task.detached` off the main actor while the catalog and the collections live on it, so this
/// crosses the hop as an immutable snapshot.
///
/// Only NON-`.distinct` entries are indexed. A live cut he owns is not grounds to suppress
/// anything — the studio recording of that song is not "a different version of the live take", it
/// is the record — so those entries simply do not participate.
struct RecVersionIndex: Sendable, Equatable {

    /// `artistKey \u{1} base` ⇒ the version signatures owned under it.
    private let byBucket: [String: Set<String>]

    static let empty = RecVersionIndex(owned: [RecVersionIdentity.Key]())

    init(owned: some Sequence<RecVersionIdentity.Key>) {
        var m: [String: Set<String>] = [:]
        for k in owned where k.isUsable && !k.isDistinct {
            m[k.bucket, default: []].insert(k.signature)
        }
        byBucket = m
    }

    var isEmpty: Bool { byBucket.isEmpty }

    /// Does he already have this record in ANOTHER version?
    ///
    /// The `signature != ` test is the "never on artist+title alone" guard, applied here rather
    /// than per-pair so the hot loop stays one dictionary lookup: an owned entry with the SAME
    /// signature is the same version, which is `RecMembership`'s question, not this one.
    func supersedes(_ candidate: RecVersionIdentity.Key) -> Bool {
        guard candidate.isUsable, !candidate.isDistinct else { return false }
        guard let owned = byBucket[candidate.bucket] else { return false }
        return owned.contains { $0 != candidate.signature }
    }

    /// String convenience for callers with no pre-computed key (the release feed).
    func supersedes(title: String, artist: String) -> Bool {
        guard !byBucket.isEmpty,
              let k = RecVersionIdentity.key(title: title, artist: artist) else { return false }
        return supersedes(k)
    }

    // ── The OWNERSHIP question (adjacent to `supersedes`, and not the same one) ───────────────

    /// **DOES HE ALREADY HAVE THIS RECORD AT ALL?** — regardless of which edition either side is.
    ///
    /// `supersedes` asks whether the candidate is a DIFFERENT VERSION of something owned, and its
    /// last clause (`signature != `) deliberately refuses to answer on artist + title alone. That
    /// guard is right for feature 6 and stays exactly as it is — but it is also why an album the
    /// owner literally has can march through the New feed: same artist, same title, same (empty)
    /// signature, so "different version" is honestly *no*.
    ///
    /// This is the other half of that sentence, and it belongs to the OWNERSHIP path: the bucket
    /// existing at all means he owns a record by this artist under this title. It is strictly
    /// broader than `supersedes` (every superseding pair shares a bucket), so the two never
    /// disagree — this one simply also covers the equal-signature case.
    ///
    /// The `.distinct` guards are unchanged in both directions: a live/acoustic/demo CANDIDATE is
    /// new music and is never suppressed, and a `.distinct` owned entry was never indexed in the
    /// first place, so owning a live album is not grounds to hide the studio record.
    func hasRecord(_ candidate: RecVersionIdentity.Key) -> Bool {
        guard candidate.isUsable, !candidate.isDistinct else { return false }
        if byBucket[candidate.bucket] != nil { return true }
        // "Pop Star" vs "Popstar" — one record, two of Apple's own spellings. See `spacelessKey`.
        // Matching is only symmetric if the OWNED side was seeded with its spaceless keys too;
        // `AppModel.ownedAlbumRecordIndex(forArtistName:)` — the one builder feeding this — does.
        guard let squashed = RecVersionIdentity.spacelessKey(candidate) else { return false }
        return byBucket[squashed.bucket] != nil
    }

    /// String convenience, for the release feed (which holds raw text, never a catalog row).
    func hasRecord(title: String, artist: String) -> Bool {
        guard !byBucket.isEmpty,
              let k = RecVersionIdentity.key(title: title, artist: artist) else { return false }
        return hasRecord(k)
    }
}
