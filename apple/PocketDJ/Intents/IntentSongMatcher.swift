import Foundation

/// Resolves a SPOKEN song request ("make me proud", "Make Me Proud by Drake", "make me prowd")
/// against the catalog for Siri / Shortcuts. Pure and nonisolated — the unit tests drive it with
/// a handful of `IndexSong`s; `IntentServices` feeds it the live catalog.
///
/// How a request is read:
///  • the WHOLE phrase as a title ("Stand by Me" must keep working), and
///  • when it contains " by ", the part before the LAST " by " as the title and the part after
///    it as the artist. An artist that doesn't match drops that reading for that song.
///
/// Title tiers (best first): exact title · exact title without its parenthetical / " - Remaster"
/// tail · prefix · whole-word substring · a typo-tolerant match (the same Optimal-String-Alignment
/// distance the Add-to sheet's `FuzzyMatch` uses, run only when nothing literal matched — it's the
/// expensive pass over a ~100k-row catalog). An agreeing artist adds to the score.
///
/// Results are deduplicated by RECORDING (`SongDuplicateJudge.key`: the same title + artist
/// indexed from two sources is one choice for Siri, not two) and cut to the TOP TIER, so Siri
/// only asks "which one?" when the request is genuinely ambiguous.
enum IntentSongMatcher {

    /// One catalog row, pre-normalized (the live service caches these per catalog revision).
    struct Row: Sendable {
        let id: String
        let name: String
        let artist: String
        /// Alphanumerics only, case + diacritics folded ("Make Me Proud!" → "makemeproud").
        let title: String
        /// `title` without parenthetical / bracketed spans and " - …" version tails.
        let base: String
        let artistKey: String
        /// Space-separated folded words of the title — whole-word substring hits.
        let words: String

        init(id: String, name: String, artist: String) {
            self.id = id
            self.name = name
            self.artist = artist
            title = IntentSongMatcher.compact(name)
            base = IntentSongMatcher.compact(IntentSongMatcher.stripVersion(name))
            artistKey = IntentSongMatcher.compact(artist)
            words = " " + IntentSongMatcher.wordKey(name) + " "
        }

        init(_ song: IndexSong) { self.init(id: song.id, name: song.name, artist: song.artist) }
    }

    struct Match: Equatable, Sendable {
        let id: String
        let score: Double
    }

    // MARK: Normalization

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
    }

    /// Folded, alphanumerics only.
    static func compact(_ s: String) -> String {
        String(String.UnicodeScalarView(fold(s).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Folded words separated by single spaces (punctuation → space).
    static func wordKey(_ s: String) -> String {
        let mapped = fold(s).unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// "Song (feat. X) [Remastered] - 2011 Remaster" → "Song".
    static func stripVersion(_ s: String) -> String {
        var t = s
        while let open = t.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            let close: Character = t[open] == "(" ? ")" : "]"
            if let end = t[open...].firstIndex(of: close) { t.removeSubrange(open...end) } else { t.removeSubrange(open...); break }
        }
        if let dash = t.range(of: " - ") { t = String(t[..<dash.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The readings of a request: whole phrase as the title, plus "<title> by <artist>".
    /// Leading filler Siri tends to pass through ("the song …") is dropped.
    static func readings(_ raw: String) -> [(title: String, artist: String?)] {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’"))
        for filler in ["the song ", "song "] where q.lowercased().hasPrefix(filler) {
            q = String(q.dropFirst(filler.count)); break
        }
        guard !q.isEmpty else { return [] }
        var out: [(String, String?)] = [(q, nil)]
        if let r = q.range(of: " by ", options: [.caseInsensitive, .backwards]) {
            let t = q[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let a = q[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !a.isEmpty { out.append((t, a)) }
        }
        return out
    }

    // MARK: Ranking

    /// Ranked, recording-deduplicated, top-tier matches. `prefer` breaks ties between copies of
    /// one recording and lifts equally-scored candidates (e.g. the song that is playing, or one
    /// already in a collection). `limit` caps the list Siri disambiguates over.
    static func rank(_ query: String, rows: [Row], prefer: (String) -> Bool = { _ in false },
                     limit: Int = 8) -> [Match] {
        let reads = readings(query)
        guard !reads.isEmpty else { return [] }
        var best: [Int: Double] = [:]              // row index → best score over the readings
        func consider(_ i: Int, _ s: Double) { if s > (best[i] ?? -1) { best[i] = s } }

        for literalOnly in [true, false] {
            for (title, artist) in reads {
                let qt = compact(title)
                guard !qt.isEmpty else { continue }
                let qw = " " + wordKey(title) + " "
                let qa = artist.map(compact)
                let qChars = Array(qt)
                for (i, row) in rows.enumerated() {
                    var s: Double
                    if let lit = literalTitleScore(qt, qw, row) {
                        s = lit
                    } else if !literalOnly, let approx = approximateTitleScore(qChars, row) {
                        s = approx
                    } else { continue }
                    if let qa, !qa.isEmpty {
                        guard let a = artistScore(qa, row.artistKey) else { continue }
                        s += a
                    }
                    consider(i, s)
                }
            }
            if !best.isEmpty { break }              // the typo pass only when nothing literal hit
        }
        guard !best.isEmpty else { return [] }

        // Dedupe by recording: keep the best-scoring (then preferred, then catalog-first) copy.
        var byRecording: [String: (i: Int, s: Double, pref: Bool)] = [:]
        for (i, s) in best {
            let row = rows[i]
            let key = SongDuplicateJudge.key(name: row.name, artist: row.artist)
            let pref = prefer(row.id)
            if let cur = byRecording[key] {
                let better = s > cur.s || (s == cur.s && pref && !cur.pref) || (s == cur.s && pref == cur.pref && i < cur.i)
                if better { byRecording[key] = (i, s, pref) }
            } else {
                byRecording[key] = (i, s, pref)
            }
        }
        let ranked = byRecording.values.sorted {
            let sa = $0.s + ($0.pref ? 5 : 0), sb = $1.s + ($1.pref ? 5 : 0)
            return sa != sb ? sa > sb : $0.i < $1.i
        }
        guard let top = ranked.first else { return [] }
        let topScore = top.s + (top.pref ? 5 : 0)
        return ranked
            .filter { topScore - ($0.s + ($0.pref ? 5 : 0)) <= tierBand }
            .prefix(limit)
            .map { Match(id: rows[$0.i].id, score: $0.s) }
    }

    /// Candidates within this many points of the best are "equally plausible" (Siri asks).
    static let tierBand: Double = 12

    private static func literalTitleScore(_ q: String, _ qWords: String, _ row: Row) -> Double? {
        if row.title == q { return 100 }
        if row.base == q { return 95 }
        let penalty = min(Double(max(row.title.count - q.count, 0)) * 0.5, 15)
        if q.count >= 3, row.base.hasPrefix(q) || row.title.hasPrefix(q) { return 80 - penalty }
        if q.count >= 4, row.words.contains(qWords) { return 65 - penalty }
        return nil
    }

    private static func approximateTitleScore(_ q: [Character], _ row: Row) -> Double? {
        let budget = FuzzyMatch.errorBudget(q.count)
        guard budget > 0 else { return nil }
        let target = Array(row.base.isEmpty ? row.title : row.base)
        // Whole-title typos only (a free-floating substring hit on a 100k catalog is noise).
        guard abs(target.count - q.count) <= budget else { return nil }
        let d = FuzzyMatch.approximateDistance(q, target)
        guard d <= budget else { return nil }
        return 50 - Double(d) * 8
    }

    private static func artistScore(_ q: String, _ artist: String) -> Double? {
        guard !artist.isEmpty else { return nil }
        if artist == q { return 30 }
        let qNoThe = q.hasPrefix("the") ? String(q.dropFirst(3)) : q
        let aNoThe = artist.hasPrefix("the") ? String(artist.dropFirst(3)) : artist
        if aNoThe == qNoThe { return 30 }
        if q.count >= 3, artist.contains(q) || q.contains(artist) { return 20 }
        let budget = FuzzyMatch.errorBudget(q.count)
        if budget > 0, FuzzyMatch.approximateDistance(Array(q), Array(artist)) <= budget { return 10 }
        return nil
    }
}
