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
/// Measured on the owner's real catalog (96,383 Apple Music rows): **4,344 title+artist groups
/// hold more than one song id, 4,822 redundant rows in all**, and 1,698 of those twins share even
/// the same `albumId` — one album whose `trackList` is literally the same song twice, a real row
/// beside an empty-`kind`/retired library placeholder. The rip path has already been hardened
/// against exactly this shape; the ranking had not been.
///
/// ── WHY THE ENGINE COULD NOT SEE IT ──────────────────────────────────────────────────────────
/// The ranking already de-duplicates CANDIDATE-vs-MEMBER twice over — `RecMembership` folds the
/// three id forms, `RecVersionIndex` folds the editions. It has never asked the other question:
/// *have I already emitted this recording IN THIS LIST?* Every accumulator appended on the raw
/// `songId`, and two ids for one recording score identically (same artist, genre, year, and — via
/// `data/timbre-aliases.json` — the byte-identical timbre vector), so they land adjacent.
///
/// ── THE IDENTITY, IN PRECEDENCE ORDER ────────────────────────────────────────────────────────
/// A row is recognised by SEVERAL keys, and two rows are the same recording if they share ANY one
/// of them — that union is why this is a union-find and not a `Set<String>` of one key each.
///
///  1. **The base id** (`SongVariant.baseId`) — folds `sng_…_clean` / `sng_…_explicit` onto the
///     recording. Identity for every other id shape, so the ordinary row costs one string.
///  2. **The Apple Music store id** — `amrec_<storeId>` carries it in the NAME (Discover / the
///     recognizer), and the indexed row that supersedes it carries the same number as
///     `appleMusicId`. Two strings with nothing textual in common, one recording. Validated
///     through `RecMembership.validStoreKey` — the ONE store-id validity rule in this app — so a
///     placeholder ("0", "", "unknown") can never fold a slice of the catalog into one identity.
///  3. **The recording key** — normalized artist + base title + the RECORDING-ALTERING part of the
///     version signature. This is the only key that can see two plain `sng_` rows for one song,
///     which is the shape the owner reported.
///
/// ── THE RECORDING KEY'S NORMALIZATION, AND ITS FALSE-MERGE RISK ──────────────────────────────
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
/// **THE FALSE-MERGE RISK, STATED PLAINLY.** Two GENUINELY DIFFERENT recordings that share one
/// artist and one title, with no version material to tell them apart, merge — "Intro", "Skit",
/// "Interlude" on two different albums by the same artist is the realistic case. That is
/// deliberate: the alternative (requiring a corroborator — same album, same store id, same
/// duration) was measured on the real catalog and refuses to merge 4,664 different-album twins,
/// which is the majority of the defect. The cost of the false merge is bounded to ONE SUGGESTION
/// SLOT, and the slot is refilled — the collapse runs BEFORE `RecComposition.compose` and before
/// `ZoneEngine.interleave`, both of which keep walking the ranking until the list is full. The
/// cost of the false SPLIT is the bug that was reported.
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

    /// Every key one candidate row can be recognised by. THE definition of "the same recording"
    /// for the recommendation surfaces — and the only one, because two answers to this question is
    /// how one recording ends up occupying two rows of one list.
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
        var out = [SongVariant.baseId(songId)]
        if let store = RecMembership.adHocStoreId(songId) { out.append(RecMembership.storeKey(store)) }
        if let am = appleMusicId, let key = RecMembership.validStoreKey(am) { out.append(key) }
        if let rec = recordingKey(version) { out.append(rec) }
        return out
    }

    /// Does this row resolve to something the app can actually stream? A valid Apple Music store
    /// id is the ONE signal the ranking has, and it is exactly the signal that separates the real
    /// library row from the retired/placeholder twin beside it: measured on the reported pair,
    /// `sng_e3ac16340485` (Fayah) carries store id 1583155083 and its twin carries none.
    ///
    /// Deliberately NOT "is this playable at all" — a vinyl or My Digital row is perfectly
    /// playable and carries no store id. It is a PREFERENCE between twins of one recording, never
    /// a filter, so the worst it can do is prefer the streamable cut of a song that also exists as
    /// a local rip.
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
        /// `identityKeys` for this row.
        var keys: [String]
        /// The caller's own grouping rank, compared BEFORE `score`. In Da Zone's pools score on
        /// different scales (a familiar row's score is how hard he has been leaning on it; a
        /// rediscovery row's is a similarity), so a cross-pool twin is settled by the POOL, not by
        /// two numbers that do not mean the same thing. `0` everywhere else.
        var tier: Int = 0
        /// The ranking score. Higher wins.
        var score: Double = 0
        /// `resolvesToStreamableAudio` — a placeholder twin must never win over a playable one.
        var playable: Bool = false

        init(id: String, keys: [String], tier: Int = 0, score: Double = 0, playable: Bool = false) {
            self.id = id
            self.keys = keys
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
    /// O(n · k) with k ≤ 3 keys per row, plus a near-flat union-find — the lists are built inside
    /// a `Task.detached` ranking over ~96k rows and cannot afford anything super-linear.
    ///
    /// ── WHICH TWIN SURVIVES, AND WHY IT IS DETERMINISTIC ─────────────────────────────────────
    ///  1. **Playable beats placeholder.** Load-bearing, not cosmetic: twins score IDENTICALLY (a
    ///     twin shares its artist, genre, year and — through the timbre alias map — its very
    ///     vector), so the score comparison is always a tie and the id tiebreak decides. On the
    ///     reported pair the unplayable id sorts FIRST, so a plain first-wins collapse would have
    ///     kept the row that cannot be streamed.
    ///  2. **Tier**, then **score** — the highest-ranked instance, as the caller ranks.
    ///  3. **Lower id** — so the answer is stable between renders and the tests are not flaky.
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
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            // Lower index roots, so group identity does not depend on visit order.
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }

        var owner: [String: Int] = [:]
        owner.reserveCapacity(candidates.count * 2)
        for (i, c) in candidates.enumerated() {
            for k in c.keys {
                if let j = owner[k] { union(i, j) } else { owner[k] = i }
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
        if a.playable != b.playable { return a.playable }
        if a.tier != b.tier { return a.tier > b.tier }
        if a.score != b.score { return a.score > b.score }
        return a.id < b.id
    }
}
