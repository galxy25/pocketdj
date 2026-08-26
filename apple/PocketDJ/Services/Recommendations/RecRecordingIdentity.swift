import Foundation

/// **ONE RECORDING, ONE ROW** — the identity a recommendation list is deduplicated on, and the
/// single pass that does it.
///
/// ── THE BUG THIS EXISTS TO MAKE IMPOSSIBLE ───────────────────────────────────────────────────
/// Reported off the "Showers" crate: *"Expressway To Your Heart" — Soul Survivors* appeared TWICE
/// in one suggestion list, adjacent rows, one carrying a filled 👍 and the other not — so they
/// were two DISTINCT rows with distinct ids naming one recording, not a view repeating an item.
/// *"Fayah (feat. Alpha P)" — Rotimi* did the same thing two rows down.
///
/// Measured on the owner's real catalog (96,383 Apple Music rows): **4,614 artist+title groups
/// hold more than one song id, 5,098 redundant rows in all**, and 1,766 of those groups sit
/// entirely inside ONE album — an album whose `trackList` is literally the same song twice, a real
/// row beside an empty-`kind`/retired library placeholder. The rip path has already been hardened
/// against exactly this shape; the ranking had not been.
///
/// ── WHY THE ENGINE COULD NOT SEE IT ──────────────────────────────────────────────────────────
/// The ranking already de-duplicates CANDIDATE-vs-MEMBER twice over — `RecMembership` folds the
/// three id forms, `RecVersionIndex` folds the editions. It has never asked the other question:
/// *have I already emitted this recording IN THIS LIST?* Every accumulator appended on the raw
/// `songId`, and two ids for one recording score identically (same artist, genre, year, and — via
/// `data/timbre-aliases.json` — the byte-identical timbre vector), so they land adjacent.
///
/// ── THE IDENTITY: ONE STRONG KEY, TWO CORROBORATED ONES ──────────────────────────────────────
/// A row is recognised by several keys, and rows sharing a key are fused into one recording — but
/// NOT unconditionally, because a wrong fusion DELETES A RECORDING FROM THE FEED and leaves no
/// trace, while a missed fusion merely shows one song twice. Those failures are not symmetric, so
/// only one key fuses on sight and the other two must survive a corroboration test:
///
///  1. **The base id** (`SongVariant.baseId`) — STRONG, fuses unconditionally. `sng_…_clean` and
///     `sng_…_explicit` are the same catalog row wearing an edition suffix; there is nothing to
///     corroborate.
///  2. **The recording key** — normalized artist + base title + the RECORDING-ALTERING part of the
///     version signature. The only key that can see two plain `sng_` rows for one song, which is
///     the shape the owner reported. Corroborated by DURATION (below).
///  3. **The Apple Music store id** — `amrec_<storeId>` carries it in the NAME (Discover / the
///     recognizer), and the indexed row that supersedes it carries the same number as
///     `appleMusicId`. Two strings with nothing textual in common, one recording. Validated
///     through `RecMembership.validStoreKey` — the ONE store-id validity rule in this app — and
///     corroborated by duration, plus recording-key agreement when NEITHER side owns the id
///     outright (see the provenance rule below).
///
/// ── WHY THE STORE ID IS NOT A 1:1 CATALOG KEY, THOUGH IT LOOKS LIKE ONE ──────────────────────
/// `IndexSong.appleMusicId` is a *resolved* id — `scripts/resolve-apple-music-catalog.mjs` matched
/// a library row to a catalog row through the iTunes Search API — so two library rows can and do
/// land on ONE store id. Measured on the owner's catalog: **321 store ids are shared by rows whose
/// recording keys DISAGREE**, 711 rows in all. Real examples, all his:
///
///   · `1514890553` — Toro y Moi "Minors" AND "Minors (Instrumental)"
///   · `1709423956` — Tourist "I Can't Keep Up" AND "I Can't Keep up - Dub Remix"
///   · `1488014200` — Brent Faiyaz "Soon Az I Get Home" AND "Home" (a different song outright)
///
/// Fusing on that id alone would have silently deleted the instrumental, the dub remix and the
/// other song — defeating, through the back door, the very protection the recording key gives a
/// remix/live/instrumental cut. So two RESOLVED store ids may fuse their rows only when the rows'
/// recording keys do not contradict each other. `validStoreKey` guards against a JUNK id ("0",
/// "unknown"); this guards against a legitimately shared one, which is a different failure.
///
/// **THE ONE STORE ID THAT IS NOT A GUESS** is the one in an `amrec_<storeId>` ID: that row was
/// MINTED from a real catalog object (the recognizer / Discover fetched it), so the number is the
/// row's own identity rather than a search result about it. A fusion where either side owns its id
/// that way keeps working on the number alone — it is the join the key was written for, and the
/// two sides routinely disagree about the title (the capture carries Apple's, the library row
/// carries the owner's). Asymmetric on purpose, and the asymmetry is the provenance, not a
/// preference: resolved-vs-resolved is the shape all 321 measured false merges take.
///
/// ── THE RECORDING KEY'S NORMALIZATION ────────────────────────────────────────────────────────
/// It is built from `RecVersionIdentity` — this repo's ONE title matcher, ported from
/// `scripts/lib/am-match.mjs` — and nothing here re-normalizes text. So the rules are exactly that
/// module's, and they are:
///   · case, punctuation, diacritics and whitespace folded; the artist reduced to `artistKey`;
///   · a `feat.` / `with` credit tail is CREDIT, not title, and is dropped;
///   · a COSMETIC parenthetical is packaging and is dropped — Remastered, Deluxe, Expanded, Bonus
///     Track Version, Mono, Explicit, "LP Version";
///   · a RECORDING-ALTERING parenthetical is KEPT and must match exactly — remix, extended, edit,
///     radio, club, dub, live, acoustic, instrumental, demo, and anything the classifier does not
///     recognise at all.
/// So "Song" merges with "Song (2019 Remaster)" and with "Song (feat. X)"; "Song" does NOT merge
/// with "Song (Extended Mix)", "Song (Live)" or with another artist's song of the same name.
///
/// ── THE DURATION CORROBORATOR, AND WHY IT IS NEEDED ──────────────────────────────────────────
/// That protection only reaches a version marker that is actually PRINTED. Live albums routinely
/// do not print one, and then artist+title alone is all the key has:
///
///   · JAY Z "Takeover" — `The Blueprint` (5:13) and `MTV Unplugged` (4:57). Two store ids, two
///     performances, one recording key. Same for "Izzo (H.O.V.A.)" (4:01 / 5:08), "Song Cry"
///     (5:02 / 7:04), "Heart of the City" (3:43 / 4:05).
///   · Daft Punk "Aerodynamic" — 3:29 on `Discovery`, 6:10 on `Daft Club`.
///   · J Dilla "Geek Down" — 1:20 on `Donuts`, 1:53 on `The Shining`.
///
/// `IndexSong.length` is the cheapest corroborator this app already has and its coverage is
/// essentially total (4,612 of the 4,614 duplicate groups carry a length on EVERY row). So: two
/// rows may not be fused on text or on a store id when both carry a length and the lengths differ
/// by more than `durationToleranceMs`. The tolerance is 5 s because master-to-master drift on one
/// genuine recording lives well below it — measured over the duplicate groups, 1,198 same-album
/// pairs are byte-identical, 626 more are within 1 s, and the plausible same-recording tail (Lou
/// Reed "Walk On the Wild Side" 4.5 s, The Crusaders "Chain Reaction" 5.0 s) stops there — while
/// every false merge listed above is 16 s or wider. A missing length is NOT evidence of anything
/// and does not block a fusion; the reported pairs are 140044 ms vs 140044 ms and 187105 ms vs
/// 187104 ms, so the fix that was asked for is untouched by this guard.
///
/// **WHAT STILL MERGES THAT ARGUABLY SHOULD NOT.** Two genuinely different recordings that share
/// an artist, a title, a version signature AND a duration to within 5 s — "Intro"/"Skit" twins on
/// two albums by one artist, at the same length. That residue is deliberate: it costs ONE
/// SUGGESTION SLOT and the slot is refilled (the collapse runs BEFORE `RecComposition.compose` and
/// before `ZoneEngine.interleave`, both of which keep walking the ranking until the list is full),
/// whereas requiring a corroborator for EVERY fusion would refuse most of the defect that was
/// reported.
///
/// ── WHY THE OWNERSHIP FILTER DOES NOT TAKE THE CORROBORATOR ──────────────────────────────────
/// `ZoneEngine.suggestions`' "already in this crate" test and `RecMembership.excluding` compare on
/// `recordingKey` alone. Deliberate, and not an inconsistency to be tidied away: those filters
/// WITHHOLD AN OFFER (the song stays one search away, and the owner can file it by hand), while
/// this collapse DELETES A ROW from a list he will never see again. The read-time membership half
/// also runs over frozen ids with no duration in reach, and one rule that behaves differently at
/// the two ends would be worse than two rules with honestly different jobs.
///
/// ── WHY A VALUE-IN / VALUE-OUT PASS ──────────────────────────────────────────────────────────
/// Same reason `RecMembership` and `RecComposition` are: the ranking runs `Task.detached` over
/// ~96k rows while the stores are `@MainActor`, and a pure pass over literals is the only shape
/// that can be unit-tested under all four id forms at once.
enum RecRecordingIdentity {

    // ========================================================================
    // MARK: - Identity
    // ========================================================================

    /// The text key is namespaced so a title can never collide with a song id (which is always
    /// `sng_…` / `amrec_…` / `smp_…` / `pdj_…`) or with a store key (`RecMembership.storeKey`,
    /// `am:<adam id>`) inside the ONE key space the collapse unions over. The base song id needs
    /// no prefix — it is already a namespace — and stays bare so this is the same key space
    /// `RecMembership` has always compared members in.
    private static let recordingPrefix = "rec:"

    /// Two lengths this far apart (milliseconds) are two different recordings. See the class doc
    /// for the measurement this number comes from.
    static let durationToleranceMs = 5_000

    /// **THE RECORDING KEY** — normalized artist + base title + the recording-altering signature.
    ///
    /// `nil` when the row carries no usable title/artist, which is the fail-open case: such a row
    /// simply does not participate in text identity and falls back to id equality.
    ///
    /// The signature is dropped for `.standard` and `.cosmetic` titles (a remaster is the same
    /// recording in different packaging) and KEPT verbatim for `.derivative` and `.distinct` ones
    /// (a remix, an edit, a live take, or a parenthetical the classifier cannot read — none of
    /// those may silently merge into the plain cut). Two rows of the SAME live take still merge,
    /// because their signatures are equal.
    static func recordingKey(_ v: RecVersionIdentity.Key?) -> String? {
        guard let v, v.isUsable else { return nil }
        let sig: String
        switch v.klass {
        case .standard, .cosmetic: sig = ""
        case .derivative, .distinct: sig = v.signature
        }
        return recordingPrefix + v.artistKey + "\u{1}" + v.base + "\u{1}" + sig
    }

    /// Every key one song id can be recognised by, FLAT — the candidate-vs-MEMBER join
    /// (`RecMembership`), which asks "is this song already in that collection" and answers by set
    /// intersection.
    ///
    /// Deliberately NOT what the list collapse uses: fusing two ranked rows needs the keys kept
    /// APART so the corroborators can be applied per key class (see `identity(…)` and `keepMask`).
    /// Here every key is an equally good reason to withhold one suggestion, which is a bounded and
    /// reversible cost.
    ///
    /// - Parameters:
    ///   - songId: the row's id, in any of the shapes this app mints.
    ///   - appleMusicId: the catalog store id when the caller has one (`IndexSong.appleMusicId` /
    ///     `ZoneEngine.Track.appleMusicId`). Absent ⇒ the store join simply does not fire.
    ///   - version: the row's pre-parsed version identity (`ZoneEngine.versionKeys`). Absent ⇒ no
    ///     text identity, id equality only.
    static func identityKeys(songId: String,
                             appleMusicId: String? = nil,
                             version: RecVersionIdentity.Key? = nil) -> [String] {
        let id = identity(songId: songId, appleMusicId: appleMusicId, version: version)
        return [id.baseId] + id.storeKeys + (id.recordingKey.map { [$0] } ?? [])
    }

    /// **THE IDENTITY OF ONE RANKED ROW**, with the key classes kept apart and the corroborating
    /// facts carried alongside them. `keepMask` is the only consumer; see the class doc for why
    /// the three keys do not all fuse on sight.
    struct Identity: Sendable, Equatable {
        /// `SongVariant.baseId` — the STRONG key. Two rows sharing it are one catalog row.
        var baseId: String
        /// The store key this row OWNS — `amrec_<storeId>`, minted from a real catalog object, so
        /// the number is the row's identity and not a guess about it. Fuses on the number alone
        /// (duration permitting): this is the Discover/recognizer join.
        var adHocStoreKey: String?
        /// The store key RESOLVED onto this library row by `resolve-apple-music-catalog.mjs`
        /// through the iTunes Search API. A candidate id, not a key: 321 of them on the owner's
        /// catalog are shared by rows that are NOT the same recording, so a fusion between two of
        /// these must also survive the recording-key test.
        var resolvedStoreKey: String?
        /// `recordingKey`. Fuses only when the durations do not contradict it.
        var recordingKey: String?
        /// `IndexSong.length` (milliseconds) — THE corroborator. `nil` is "unknown", never "0".
        var lengthMs: Int?

        /// Both store keys, flattened — for the membership join, which does not care where an id
        /// came from because the cost of its false positive is one withheld suggestion.
        var storeKeys: [String] { [adHocStoreKey, resolvedStoreKey].compactMap { $0 } }
    }

    /// Build the identity of one ranked row.
    ///
    /// - Parameters:
    ///   - songId: the row's id, in any of the shapes this app mints.
    ///   - appleMusicId: the catalog store id when the caller has one.
    ///   - version: the row's pre-parsed version identity (`ZoneEngine.versionKeys`).
    ///   - lengthMs: the row's duration in milliseconds (`IndexSong.length`). Absent or
    ///     non-positive ⇒ unknown, which corroborates nothing and blocks nothing.
    static func identity(songId: String,
                         appleMusicId: String? = nil,
                         version: RecVersionIdentity.Key? = nil,
                         lengthMs: Int? = nil) -> Identity {
        let adHoc = RecMembership.adHocStoreId(songId).map { RecMembership.storeKey($0) }
        var resolved = appleMusicId.flatMap { RecMembership.validStoreKey($0) }
        if resolved == adHoc { resolved = nil }   // one id, not two keys
        return Identity(baseId: SongVariant.baseId(songId),
                        adHocStoreKey: adHoc,
                        resolvedStoreKey: resolved,
                        recordingKey: recordingKey(version),
                        lengthMs: (lengthMs ?? 0) > 0 ? lengthMs : nil)
    }

    /// Does this row resolve to something the app can actually stream? A valid Apple Music store
    /// id is the ONE signal the ranking has, and it is exactly the signal that separates the real
    /// library row from the retired/placeholder twin beside it: measured on the reported pair,
    /// `sng_e3ac16340485` (Fayah) carries store id 1583155083 and its twin carries none.
    ///
    /// Deliberately NOT "is this playable at all" — a vinyl or My Digital row is perfectly
    /// playable and carries no store id. It is a PREFERENCE between twins of one recording and
    /// never a filter, and the POOL is asked before it (see `prefers`), so the worst it can do is
    /// prefer the streamable cut of a song that also exists as a local rip, inside one pool. THE
    /// KNOWN GAP: that preference is upside down for an offline listener, and this file has no
    /// signal for "there is a burned copy of this on the device" to fix it with — the burn store
    /// is `@MainActor` and the ranking is not.
    static func resolvesToStreamableAudio(appleMusicId: String?) -> Bool {
        guard let appleMusicId else { return false }
        return RecMembership.validStoreKey(appleMusicId) != nil
    }

    // ========================================================================
    // MARK: - The collapse (the single choke point)
    // ========================================================================

    /// One ranked row, as the collapse sees it.
    struct Candidate: Sendable {
        /// The row's id — carried for the deterministic last tiebreak only.
        var id: String
        /// `identity(…)` for this row.
        var identity: Identity
        /// The caller's own grouping rank, compared BEFORE `score`. In Da Zone's pools score on
        /// different scales (a familiar row's score is how hard he has been leaning on it; a
        /// rediscovery row's is a similarity), so a cross-pool twin is settled by the POOL, not by
        /// two numbers that do not mean the same thing. `0` everywhere else.
        var tier: Int = 0
        /// The ranking score. Higher wins.
        var score: Double = 0
        /// `resolvesToStreamableAudio` — a placeholder twin must never win over a playable one.
        var playable: Bool = false

        init(id: String, identity: Identity, tier: Int = 0, score: Double = 0,
             playable: Bool = false) {
            self.id = id
            self.identity = identity
            self.tier = tier
            self.score = score
            self.playable = playable
        }
    }

    /// **THE PASS.** `true` for every row that survives, aligned to the input — so a caller with
    /// three parallel pools slices one mask rather than running three collapses that cannot see
    /// each other (a cross-pool twin is the case a per-pool collapse would miss, and In Da Zone
    /// has one twin in the familiar pool and one in the rediscovery pool exactly as often as it
    /// has both in one).
    ///
    /// O(n · k) with k ≤ 4 keys per row, plus a near-flat union-find — the lists are built inside
    /// a `Task.detached` ranking over ~96k rows and cannot afford anything super-linear.
    ///
    /// ── THE THREE PASSES, IN DESCENDING TRUST ────────────────────────────────────────────────
    ///  1. the base id, unconditionally;
    ///  2. the recording key, unless the two groups' durations contradict it;
    ///  3. the store id, unless the durations contradict it — and, when NEITHER side owns its id
    ///     outright (both are search-resolved `appleMusicId`s), unless the recording keys do.
    ///
    /// A refused fusion errs toward SPLITTING (the row is emitted twice at worst), which is the
    /// direction this pass is required to fail in. The union-find carries each group's recording
    /// key and its duration RANGE forward, so a refusal cannot be walked around transitively:
    /// fusing A into B widens B's range, and the next candidate is tested against the widened one.
    ///
    /// ── WHICH TWIN SURVIVES, AND WHY IT IS DETERMINISTIC ─────────────────────────────────────
    ///  1. **Tier** — the highest-ranked POOL, asked FIRST. A song he actually played (In Da
    ///     Zone's familiar pool) may not be replaced by its twin sitting in the last-resort
    ///     fallback pool: the queue would then label a song he played yesterday "Buried", and the
    ///     fallback row is ranked on `auxOnly` alone, which is not a ranking at all.
    ///  2. **Playable beats placeholder**, within one pool. Load-bearing, not cosmetic: twins
    ///     score identically often enough (a twin shares its artist, genre, year and — through the
    ///     timbre alias map — its very vector), and where they do NOT, the retired placeholder is
    ///     the one that scores HIGHER: it carries no play history, so the dormancy term rewards
    ///     it. Ranking a row the app cannot stream above one it can is never the answer inside a
    ///     pool. On the reported pair the unplayable id also sorts first alphabetically, so a
    ///     plain first-wins collapse would have kept it.
    ///  3. **Score** — the highest-ranked instance, as the caller ranks, once both above agree.
    ///  4. **Lower id** — so the answer is stable between renders and the tests are not flaky.
    ///
    /// The survivor keeps ITS OWN position in the input order; nothing is reordered.
    static func keepMask(_ candidates: [Candidate]) -> [Bool] {
        guard candidates.count > 1 else { return Array(repeating: true, count: candidates.count) }

        // Union-find over row indices. A plain "first key wins" dictionary is NOT enough: rows
        // A(id) and B(title) can be joined only by a later row C carrying both keys, and a
        // dictionary would leave A and B in different groups and emit them both.
        var parent = Array(candidates.indices)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var i = x
            while parent[i] != i { let next = parent[i]; parent[i] = root; i = next }
            return root
        }

        // ── THE GROUP'S FACTS, MAINTAINED AT ITS ROOT ────────────────────────────────────────
        // A group's recording key (and whether it holds more than one — which only the strong id
        // key can produce, e.g. `sng_x` beside `sng_x_clean` titled "(Clean)"), plus the range of
        // durations it has absorbed. Kept at the root so a fusion is tested against the whole
        // group rather than against whichever row happened to claim the key first.
        var groupRec = candidates.map(\.identity.recordingKey)
        var groupRecMixed = [Bool](repeating: false, count: candidates.count)
        var groupLo = candidates.map(\.identity.lengthMs)
        var groupHi = groupLo

        /// Do the two groups' durations prove they are different recordings?
        func durationsContradict(_ a: Int, _ b: Int) -> Bool {
            guard let aLo = groupLo[a], let aHi = groupHi[a],
                  let bLo = groupLo[b], let bHi = groupHi[b] else { return false }
            return aLo - bHi > durationToleranceMs || bLo - aHi > durationToleranceMs
        }

        /// Do the two groups name recordings the title matcher says are different? Only asked of
        /// the store-id key — the recording key IS this comparison.
        func recordingsContradict(_ a: Int, _ b: Int) -> Bool {
            guard let x = groupRec[a], let y = groupRec[b],
                  !groupRecMixed[a], !groupRecMixed[b] else { return false }
            return x != y
        }

        /// Fuse two groups and carry their facts into the surviving root.
        func fuse(_ i: Int, _ j: Int) {
            let a = find(i), b = find(j)
            guard a != b else { return }
            let rec: String?
            var mixed = groupRecMixed[a] || groupRecMixed[b]
            switch (groupRec[a], groupRec[b]) {
            case let (x?, y?):
                rec = x
                if x != y { mixed = true }
            case let (x?, nil): rec = x
            case let (nil, y): rec = y
            }
            let lo = [groupLo[a], groupLo[b]].compactMap { $0 }.min()
            let hi = [groupHi[a], groupHi[b]].compactMap { $0 }.max()
            // Lower index roots, so group identity does not depend on visit order.
            let root = min(a, b), merged = max(a, b)
            parent[merged] = root
            groupRec[root] = rec
            groupRecMixed[root] = mixed
            groupLo[root] = lo
            groupHi[root] = hi
        }

        // PASS 1 — the strong key.
        var byBaseId: [String: Int] = [:]
        byBaseId.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            if let j = byBaseId[c.identity.baseId] { fuse(i, j) } else { byBaseId[c.identity.baseId] = i }
        }

        // PASS 2 — the recording key, corroborated by duration.
        var byRecording: [String: Int] = [:]
        for (i, c) in candidates.enumerated() {
            guard let key = c.identity.recordingKey else { continue }
            guard let j = byRecording[key] else { byRecording[key] = i; continue }
            let a = find(i), b = find(j)
            guard a != b, !durationsContradict(a, b) else { continue }
            fuse(a, b)
        }

        // PASS 3 — the store id, corroborated by duration, and by the recording key whenever the
        // number is a SEARCH RESULT on both sides rather than either row's own identity.
        var byStore: [String: (row: Int, owned: Bool)] = [:]
        for (i, c) in candidates.enumerated() {
            for (key, owned) in [(c.identity.adHocStoreKey, true),
                                 (c.identity.resolvedStoreKey, false)] {
                guard let key else { continue }
                guard let prior = byStore[key] else { byStore[key] = (i, owned); continue }
                let a = find(i), b = find(prior.row)
                guard a != b, !durationsContradict(a, b) else { continue }
                guard owned || prior.owned || !recordingsContradict(a, b) else { continue }
                fuse(a, b)
            }
        }

        var best: [Int: Int] = [:]
        best.reserveCapacity(candidates.count)
        for i in candidates.indices {
            let root = find(i)
            guard let b = best[root] else { best[root] = i; continue }
            if prefers(candidates[i], over: candidates[b]) { best[root] = i }
        }
        return candidates.indices.map { best[find($0)] == $0 }
    }

    /// The survivor rule, in one place so the tests can pin it.
    private static func prefers(_ a: Candidate, over b: Candidate) -> Bool {
        if a.tier != b.tier { return a.tier > b.tier }
        if a.playable != b.playable { return a.playable }
        if a.score != b.score { return a.score > b.score }
        return a.id < b.id
    }
}
