import Foundation

/// THE TIMBRE CORPUS ON DEVICE — song id → 14-axis vector, loaded from the published
/// `timbre.json` (2.9 MB, 14,916 rows: 12,049 own vectors + 2,867 same-recording aliases).
///
/// ── WHY A SEPARATE FETCH AND NOT A FIELD ON THE CATALOG INDEXES ──────────────────────────────
/// The vectors live in `public/timbre.json` (written by `scripts/fold-timbre.mjs`) and ride the
/// existing catalog deploy; the per-song indexes deliberately do NOT carry them — 14 doubles ×
/// 96k rows would grow the 49.9 MB Apple Music index that every launch decodes, to serve a term
/// only the For You refresh reads. This store fetches the small file, once, when a ranking
/// actually wants it.
///
/// ── THE PERF RULE THIS FILE EXISTS TO OBEY ───────────────────────────────────────────────────
/// An eager decode of a corpus this size in a view body is the exact bug this repo keeps
/// re-finding (Browse search, the catalog load, `ZoneEngine.versionKeys` all moved off the main
/// actor for it). So: an ACTOR, decode happens on the actor (never the main actor), the decoded
/// map is memoized for the process lifetime, and the only thing that crosses back is the final
/// `[String: [String: Double]]` value. The For You refresh awaits it off the paint path — the
/// grid renders the previous snapshot while this loads.
///
/// ── OFFLINE-FIRST, THE `CatalogService` PATTERN ──────────────────────────────────────────────
/// Same disk cache + HTTP-validator conditional GET (`CatalogService`'s statics, reused rather
/// than re-implemented): a 304 serves the cached bytes, a network failure serves the last good
/// copy, and a cold install with no network serves nothing — the term then simply stays dead
/// (`ZoneEngine` treats an empty map as "pre-v2 ranking", fail open by construction).
actor TimbreCatalog {

    static let shared = TimbreCatalog()

    /// Where the corpus lives — beside the catalog indexes, same CDN, same deploy.
    nonisolated static var url: URL { Config.catalogBase.appendingPathComponent("timbre.json") }

    /// Re-ask the CDN at most this often. The corpus changes when a fold lands (nightly at most),
    /// so a For You refresh minutes after the last one re-uses the memo without a network trip.
    private static let refreshIntervalMs: Double = 6 * 3_600_000

    private var memo: [String: SimilarityFamilies.TimbreVector]?
    private var fetchedAtMs: Double = 0
    /// Test seam: a fixture URL (and no network) — set by `configureForTesting`.
    private var fixtureURL: URL?

    /// The corpus, memoized. NEVER throws: every failure path returns the best map this install
    /// can produce — the memo, the disk cache, or empty (⇒ the timbre term is dead this round).
    func vectors(nowMs: Double = Date().timeIntervalSince1970 * 1000) async -> [String: SimilarityFamilies.TimbreVector] {
        if let fixtureURL {
            if let memo { return memo }
            let m = (try? Data(contentsOf: fixtureURL)).flatMap(Self.decode) ?? [:]
            memo = m
            return m
        }
        if let memo, nowMs - fetchedAtMs < Self.refreshIntervalMs { return memo }
        let url = Self.url
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            if let v = CatalogService.loadValidator(for: url) {
                if let lm = v.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
                if let et = v.etag { request.setValue(et, forHTTPHeaderField: "If-None-Match") }
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 304 {
                let m = memo ?? cachedMap() ?? [:]
                memo = m
                fetchedAtMs = nowMs
                return m
            }
            guard (200..<300).contains(http.statusCode), let decoded = Self.decode(data) else {
                throw URLError(.badServerResponse)
            }
            // Persist only after a valid decode — never cache the SPA-shell HTML a missing file
            // comes back as (the CatalogService lesson).
            CatalogService.writeCache(data, for: url,
                                      validator: .init(lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                                                       etag: http.value(forHTTPHeaderField: "ETag")))
            memo = decoded
            fetchedAtMs = nowMs
            return decoded
        } catch {
            let m = memo ?? cachedMap() ?? [:]
            if memo == nil, !m.isEmpty { memo = m }
            // No stamp on `fetchedAtMs`: the next refresh should retry the network rather than
            // ride a failure for six hours.
            return m
        }
    }

    private func cachedMap() -> [String: SimilarityFamilies.TimbreVector]? {
        guard let src = CatalogService.cacheFileURL(for: Self.url),
              let data = try? Data(contentsOf: src) else { return nil }
        return Self.decode(data)
    }

    /// UNIT-TEST SEAM: serve `fixture` (a timbre.json document on disk) and never touch the
    /// network. Pass nil to reset.
    func configureForTesting(fixture: URL?) {
        fixtureURL = fixture
        memo = nil
        fetchedAtMs = 0
    }

    // ── The document (fold-timbre.mjs shape) ────────────────────────────────────────────────
    //   { "v":1, "timbreVersion":1,
    //     "songs": { "sng_a": {"v":1,"f":{…14 axes…}},   ← own vector, stamped with ITS calibration
    //                "sng_b": {"alias":"sng_a"} } }      ← same recording, other id
    // Aliases resolve here, at read time, ONE hop — an alias to an alias is a build error
    // upstream and resolves to nothing rather than chasing a chain (build-rec-features.mjs'
    // `timbreMap` rule, mirrored).

    private struct Doc: Decodable {
        struct Row: Decodable {
            /// `Double?` VALUES on purpose — the REAL corpus carries the odd `null` axis
            /// (`analyze-timbre.py`'s `norm()` returns None when e.g. the HPSS energy is zero;
            /// 2 of 12,049 rows on 2026-08-11). A strict `[String: Double]` decode throws on the
            /// first one and would silently discard the WHOLE corpus for two bad axes.
            var f: [String: Double?]?
            var alias: String?
            /// Per-row calibration stamp, when the fold wrote one. A row disagreeing with the
            /// document's own version is dropped ALONE — one stale row must not kill the corpus.
            ///
            /// NAMED `v`, because that is the key `fold-timbre.mjs` actually writes
            /// (`songs[id] = { v: r.v, f: r.f }`). A reader's field names are part of the artifact
            /// contract, and the artifact is the arbiter: spelled anything else this guard would
            /// be dead code that only a hand-written fixture could ever exercise.
            var v: Int?
        }
        var songs: [String: Row]
        /// Which calibration produced these numbers. Absent ⇒ 1, the version that shipped before
        /// the field existed.
        var timbreVersion: Int?
    }

    nonisolated static func decode(_ data: Data) -> [String: SimilarityFamilies.TimbreVector]? {
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return nil }
        // ── REFUSE TO MIX CALIBRATIONS ──────────────────────────────────────────────────────
        // THE DEVICE IS THE READER THAT ACTUALLY MEASURES. `fold-timbre.mjs`,
        // `build-rec-features.mjs` and the Lambda all refuse a corpus at another calibration; this
        // file is the fourth consumer and the only one that computes the sound door's distances
        // against `timbreNoiseFloor` / `soundAdmitMargin` / `soundAdmitMaxSpread` / `timbreDecay`
        // — constants written in v1 rail units. The rails ARE the units, so a distance taken
        // across two calibrations is arithmetic on incomparable numbers, and it produces a
        // perfectly plausible-looking float: the dangerous kind of wrong.
        //
        // And this reader is the one that can actually MEET such a corpus. `timbre.json` rides the
        // catalog CDN; the app ships through TestFlight; the two update independently, so a device
        // on the previous build downloads the next calibration's corpus the moment it lands.
        //
        // MIGRATING is a build-time job, never a device one — the published corpus arrives at ONE
        // version, always the current one, so a device never has to reconcile two.
        //
        // Refusing means an EMPTY map, which this file's contract already defines as "the timbre
        // term is dead this round": fail open, the ranking falls back to pre-timbre behaviour,
        // nothing crashes and nothing is scored on numbers it cannot read.
        let docVersion = doc.timbreVersion ?? 1
        guard docVersion == SimilarityFamilies.timbreVersion else { return [:] }

        // OWN vectors first. Null/non-finite axes drop; the distance already treats a missing
        // axis as "does not vote". A row that then fails `isUsableTimbreRow` is QUARANTINED
        // rather than admitted with `!clean.isEmpty`: a single surviving axis passed that old
        // test, and the 32 degenerate rows the published corpus still carries are all the same
        // point — they read as each other's nearest neighbours and recommend each other. The
        // fold quarantines them too, but a corpus published before the fold learned to is
        // already out there on devices, and a reader must not depend on the writer's discipline.
        var own: [String: SimilarityFamilies.TimbreVector] = [:]
        own.reserveCapacity(doc.songs.count)
        for (id, row) in doc.songs {
            guard let f = row.f else { continue }
            // A row whose OWN stamp disagrees with the document's drops ALONE. One stale row is a
            // lost song; a refused corpus is a dead feature, and they are not the same failure.
            if let rowVersion = row.v, rowVersion != docVersion { continue }
            // A PRESENT-but-null axis has to be caught HERE and not in the predicate, because
            // `TimbreVector` ([String: Double]) cannot express the difference between an axis the
            // extractor never wrote and one it wrote as `null` — and that difference is the whole
            // verdict. `null` means the measurement was attempted and came back undefined (both
            // ratio axes divide by the window's energy), so the 14-finite-numbers contract is
            // violated and the row is a FAILED capture, not a partial one. Strip first and it
            // silently degrades to a 13-axis row that passes the floor — which is exactly how the
            // device kept two rows the fold had already quarantined.
            let brokenAxis = SimilarityFamilies.timbreAxes.contains { axis in
                f.keys.contains(axis) && (f[axis] ?? nil)?.isFinite != true
            }
            if brokenAxis { continue }
            let clean = f.compactMapValues { $0?.isFinite == true ? $0 : nil }
            if SimilarityFamilies.isUsableTimbreRow(clean) { own[id] = clean }
        }
        // Aliases resolve against the OWN-vector set only — exactly ONE hop, deterministically.
        // Resolving against the accumulating output would let an alias-to-alias chain whenever
        // dictionary iteration happened to visit the middle link first (fold-timbre drops such
        // rows at build time, but a reader must not depend on the writer's discipline).
        var out = own
        for (id, row) in doc.songs {
            if out[id] == nil, let alias = row.alias, let f = own[alias] { out[id] = f }
        }
        return out
    }
}
