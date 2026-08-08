import Foundation

/// Typo-tolerant name matching for the "filter this list by what I typed" fields
/// (first user: the Add-to-collection sheet's playlist/pocket search).
///
/// A plain `localizedCaseInsensitiveContains` is not what people type at a picker: they
/// drop vowels and spaces ("80snght" for "80s Night"), type initials ("fnm" for "Friday
/// Night Mix"), and mistype ("80s Nigth"). So matching runs three widening passes and
/// stops at the first that hits, scoring HIGHER the more literal the hit was:
///
///  1. **Literal** — equal / prefix / substring of the compacted name.
///  2. **Subsequence** — every query character appears in order, with bonuses for
///     contiguous runs and for landing on word starts (that's what makes initials work).
///  3. **Approximate substring** — Optimal-String-Alignment distance (Levenshtein +
///     adjacent transposition) with a FREE start and end in the candidate, so the query
///     may misspell a word in the middle of a longer name. The error budget scales with
///     the query length (1 typo up to 7 chars, then ~1 per 4), which keeps a 3-letter
///     query from matching everything.
///
/// Scores are only meaningful RELATIVE to each other (rank a list), never as a threshold
/// a caller invents; `nil` means "no match" and is the only signal to hide a row.
enum FuzzyMatch {

    // MARK: - Normalization

    /// Diacritic-folded + whitespace-collapsed, CASE PRESERVED — word starts are read off
    /// this (a camel-cased "FridayNightMix" has three of them).
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Normalized, lowercased AND stripped of every non-alphanumeric, so "80s Night" and
    /// "80s-night" and "80snight" all compare equal. This is what every pass works over.
    static func compact(_ s: String) -> [Character] { prepare(s).chars }

    /// ONE pass produces the compact characters AND the word-start indices together, so the
    /// two can never drift apart (lowercasing a string as a whole can change its length —
    /// "İ" → "i̇" — which would slide every recorded index by one).
    private static func prepare(_ s: String) -> (chars: [Character], starts: Set<Int>) {
        var chars: [Character] = []
        var starts: Set<Int> = []
        var atStart = true
        var previous: Character?
        for ch in normalize(s) {
            guard ch.isLetter || ch.isNumber else { atStart = true; continue }
            let idx = chars.count
            if atStart { starts.insert(idx) }
            else if let p = previous, p.isNumber != ch.isNumber { starts.insert(idx) }
            else if let p = previous, p.isLowercase, ch.isUppercase { starts.insert(idx) }
            atStart = false
            previous = ch
            chars.append(Character(String(ch).lowercased().first.map(String.init) ?? String(ch)))
        }
        return (chars, starts)
    }

    // MARK: - Scoring

    /// `nil` ⇒ no match. Higher = better. An EMPTY query matches everything at score 0 so
    /// a caller can rank an unfiltered list without special-casing.
    static func score(query: String, candidate: String) -> Double? {
        let q = compact(query)
        guard !q.isEmpty else { return 0 }
        // Word starts ride in the same index space as the compact characters — the
        // subsequence pass rewards hitting them, which is what makes "fnm" find
        // "Friday Night Mix".
        let (c, starts) = prepare(candidate)
        guard !c.isEmpty else { return nil }

        if let s = literalScore(q, c) { return s }
        if let s = subsequenceScore(q, c, wordStarts: starts) { return s }
        if let s = approximateScore(q, c) { return s }
        return nil
    }

    static func matches(query: String, candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }

    /// Filter + rank `items` by `name`. Empty/whitespace query ⇒ the input order, untouched
    /// (the caller's own sort stays authoritative when nobody is searching). Ties keep the
    /// caller's order — `sorted(by:)` isn't stable, so the index rides along in the key.
    static func rank<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { idx, item -> (Int, Double, T)? in
                guard let s = score(query: query, candidate: name(item)) else { return nil }
                return (idx, s, item)
            }
            .sorted { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 > b.1 }
            .map(\.2)
    }

    // MARK: - Pass 1: literal

    private static func literalScore(_ q: [Character], _ c: [Character]) -> Double? {
        if q == c { return 1000 }
        if c.count > q.count, Array(c[0..<q.count]) == q {
            // Prefix: the shorter the remainder, the better the hit.
            return 900 - lengthPenalty(q.count, c.count)
        }
        if let at = firstIndex(of: q, in: c) {
            // Substring: earlier is better.
            return 800 - Double(min(at, 40)) - lengthPenalty(q.count, c.count)
        }
        return nil
    }

    // MARK: - Pass 2: subsequence

    /// Greedy left-to-right subsequence walk. Bonuses: +6 per character that continues the
    /// previous match (contiguity) and +8 per character that lands on a word start.
    private static func subsequenceScore(_ q: [Character], _ c: [Character],
                                         wordStarts: Set<Int>) -> Double? {
        var qi = 0, bonus = 0.0, lastHit = -2, gaps = 0.0
        for (ci, ch) in c.enumerated() {
            guard qi < q.count else { break }
            guard ch == q[qi] else { continue }
            if ci == lastHit + 1 { bonus += 6 }
            if wordStarts.contains(ci) { bonus += 8 }
            if lastHit >= 0 { gaps += Double(ci - lastHit - 1) }
            lastHit = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        return 500 + bonus - min(gaps, 60) - lengthPenalty(q.count, c.count)
    }

    // MARK: - Pass 3: approximate substring (typos)

    /// Optimal String Alignment distance with a free start/end in `c` — the classic
    /// "approximate substring" DP: row 0 is all zeros (start anywhere) and the answer is
    /// the minimum of the last row (end anywhere). Handles substitution, insertion,
    /// deletion, and adjacent transposition ("Nigth" → "Night").
    private static func approximateScore(_ q: [Character], _ c: [Character]) -> Double? {
        let budget = errorBudget(q.count)
        guard budget > 0 else { return nil }
        let d = approximateDistance(q, c)
        guard d <= budget else { return nil }
        return 300 - Double(d) * 40 - lengthPenalty(q.count, c.count)
    }

    /// Errors allowed for a query of `n` characters: none below 4 (a 3-letter query with a
    /// typo matches almost anything), 1 up to 7, then one more per 4 characters.
    static func errorBudget(_ n: Int) -> Int {
        guard n >= 4 else { return 0 }
        return max(1, n / 4)
    }

    /// Minimum OSA distance between `q` and ANY contiguous window of `c`.
    static func approximateDistance(_ q: [Character], _ c: [Character]) -> Int {
        guard !q.isEmpty else { return 0 }
        guard !c.isEmpty else { return q.count }
        let n = c.count
        var prev2 = [Int](repeating: 0, count: n + 1)   // row i-2 (transposition lookback)
        var prev = [Int](repeating: 0, count: n + 1)    // row i-1: free start ⇒ all zeros
        var cur = [Int](repeating: 0, count: n + 1)
        for i in 1...q.count {
            cur[0] = i                                  // consuming query chars costs
            for j in 1...n {
                let cost = q[i - 1] == c[j - 1] ? 0 : 1
                var best = min(prev[j] + 1,             // deletion (skip a query char)
                               cur[j - 1] + 1,          // insertion (skip a candidate char)
                               prev[j - 1] + cost)      // match / substitution
                if i > 1, j > 1, q[i - 1] == c[j - 2], q[i - 2] == c[j - 1] {
                    best = min(best, prev2[j - 2] + 1)  // adjacent transposition
                }
                cur[j] = best
            }
            prev2 = prev; prev = cur
        }
        return prev.min() ?? q.count
    }

    // MARK: - Helpers

    private static func firstIndex(of needle: [Character], in hay: [Character]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }

    /// Longer names match less well than short ones for the same query (a 4-char query is a
    /// better hit on "Mix" than on a 60-character name). Capped so it can never flip tiers.
    private static func lengthPenalty(_ q: Int, _ c: Int) -> Double {
        min(Double(max(c - q, 0)) * 0.5, 60)
    }
}
