import Foundation

/// The Collectors Puzzle round configuration — filters, weighting, and the 1–3 target
/// collections. Every field decodes with `try?` + default (the collections-schema
/// doctrine) so a settings blob written by any build always loads.
struct PuzzleSettings: Codable, Equatable {
    enum Bias: String, Codable, CaseIterable { case off, favor, avoid }
    enum MembershipMode: String, Codable, CaseIterable { case off, inAny, notInAny }

    var roundSeconds: Int = 120                    // 60 / 120 / 180 / 300
    /// favor = most-played up-weighted; avoid = never/least-played up-weighted.
    ///
    /// LIFETIME plays only — deliberately says nothing about WHEN. `recencyBias` is the separate
    /// axis, and the two are independent settings because "played a lot, years ago" and "played
    /// once yesterday" are different rounds. The meaning of this field has NOT changed: existing
    /// scoreboard rows keep exactly the semantics they were recorded under.
    var playCountBias: Bias = .off
    /// favor = recently-played up-weighted; avoid = long-unplayed/never-played up-weighted.
    /// Smooth exponential decay (`PlayRecency`), not a "last 30 days" cliff — on a library whose
    /// median song was last played 5.8 years ago a cliff scores 99.5% of it identically zero.
    var recencyBias: Bias = .off
    /// favor = ♥ up-weighted; avoid = non-♥ up-weighted.
    var favoriteBias: Bias = .off
    /// Empty = all genres; else HARD filter to these `Genre.category` names.
    var genreCategories: Set<String> = []
    /// HARD year filter when set (nil-year songs drop only when a bound is set).
    var yearMin: Int? = nil
    var yearMax: Int? = nil
    /// HARD membership filter over `membershipCollectionIds`.
    var membershipMode: MembershipMode = .off
    var membershipCollectionIds: Set<String> = []  // pls_/pkt_ ids
    /// How hard to bias the round's cards toward the TARGET collections.
    enum Similarity: String, Codable, CaseIterable { case off, on, strict }

    /// 0–3 target collections (OPTIONAL — with none, every card is filed through the Add-to
    /// picker instead); order = assign-button order.
    var targetCollectionIds: [String] = []
    /// Draw cards SIMILAR to the target collections — artist / genre / lyrical content / year /
    /// membership in other collections / the playback-history graph. IGNORED when no targets
    /// are selected (there is then nothing to be similar to).
    var similarity: Similarity = .on

    init() {}

    enum CodingKeys: String, CodingKey {
        case roundSeconds, playCountBias, favoriteBias, genreCategories,
             yearMin, yearMax, membershipMode, membershipCollectionIds, targetCollectionIds,
             similarity, recencyBias
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roundSeconds = (try? c.decode(Int.self, forKey: .roundSeconds)) ?? 120
        playCountBias = (try? c.decode(Bias.self, forKey: .playCountBias)) ?? .off
        // A blob written before the recency axis existed decodes to `.off` — so every stored
        // round, and every scoreboard row's replay of one, keeps behaving exactly as recorded.
        recencyBias = (try? c.decode(Bias.self, forKey: .recencyBias)) ?? .off
        favoriteBias = (try? c.decode(Bias.self, forKey: .favoriteBias)) ?? .off
        genreCategories = (try? c.decode(Set<String>.self, forKey: .genreCategories)) ?? []
        yearMin = try? c.decode(Int.self, forKey: .yearMin)
        yearMax = try? c.decode(Int.self, forKey: .yearMax)
        membershipMode = (try? c.decode(MembershipMode.self, forKey: .membershipMode)) ?? .off
        membershipCollectionIds = (try? c.decode(Set<String>.self, forKey: .membershipCollectionIds)) ?? []
        targetCollectionIds = (try? c.decode([String].self, forKey: .targetCollectionIds)) ?? []
        // Lenient decode IS the migration: a blob written by the build before similarity
        // existed decodes to `.on`, and that older build ignores the key on a downgrade. No
        // version bump, no migration step (the collections-schema doctrine above).
        similarity = (try? c.decode(Similarity.self, forKey: .similarity)) ?? .on
    }

    /// mm:ss render of the round length ("2:00").
    var roundLengthLabel: String {
        String(format: "%d:%02d", roundSeconds / 60, roundSeconds % 60)
    }

    /// One-line human summary for the scoreboard: "2:00 · ♥ favor · hip-hop · 1990–1999 · 3 targets".
    var summaryLine: String {
        var parts: [String] = [roundLengthLabel]
        switch favoriteBias {
        case .favor: parts.append("♥ favor")
        case .avoid: parts.append("♥ avoid")
        case .off: break
        }
        switch playCountBias {
        case .favor: parts.append("most played")
        case .avoid: parts.append("least played")
        case .off: break
        }
        // A SEPARATE clause, never merged into the one above: "most played" and "recently played"
        // are different claims and a round can be both at once.
        switch recencyBias {
        case .favor: parts.append("recently played")
        case .avoid: parts.append("not played lately")
        case .off: break
        }
        if !genreCategories.isEmpty {
            parts.append(genreCategories.sorted { Genre.order(of: $0) < Genre.order(of: $1) }
                .joined(separator: "+"))
        }
        switch (yearMin, yearMax) {
        case let (lo?, hi?): parts.append("\(lo)–\(hi)")
        case let (lo?, nil): parts.append("\(lo)+")
        case let (nil, hi?): parts.append("–\(hi)")
        default: break
        }
        switch membershipMode {
        case .inAny: parts.append("in \(membershipCollectionIds.count)")
        case .notInAny: parts.append("not-in \(membershipCollectionIds.count)")
        case .off: break
        }
        // Targets are OPTIONAL: "0 targets" would be both ugly and wrong — a target-less
        // round is the free-file mode, where every card goes through the Add-to picker.
        // Old rows keep their old text (`settingsSummary` is a stored String?, never re-derived).
        switch targetCollectionIds.count {
        case 0: parts.append("free file")
        case 1: parts.append("1 target")
        case let n: parts.append("\(n) targets")
        }
        // Only when it applies AND isn't the default — the line has to stay short.
        if !targetCollectionIds.isEmpty {
            switch similarity {
            case .strict: parts.append("similar+")
            case .off: parts.append("any")
            case .on: break
            }
        }
        return parts.joined(separator: " · ")
    }
}
