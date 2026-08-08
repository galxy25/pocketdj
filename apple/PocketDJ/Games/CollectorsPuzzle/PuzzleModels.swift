import Foundation

/// The Collectors Puzzle round configuration — filters, weighting, and the 1–3 target
/// collections. Every field decodes with `try?` + default (the collections-schema
/// doctrine) so a settings blob written by any build always loads.
struct PuzzleSettings: Codable, Equatable {
    enum Bias: String, Codable, CaseIterable { case off, favor, avoid }
    enum MembershipMode: String, Codable, CaseIterable { case off, inAny, notInAny }

    var roundSeconds: Int = 120                    // 60 / 120 / 180 / 300
    /// favor = most-played up-weighted; avoid = never/least-played up-weighted.
    var playCountBias: Bias = .off
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
    /// 1–3 target collections; order = assign-button order.
    var targetCollectionIds: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case roundSeconds, playCountBias, favoriteBias, genreCategories,
             yearMin, yearMax, membershipMode, membershipCollectionIds, targetCollectionIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roundSeconds = (try? c.decode(Int.self, forKey: .roundSeconds)) ?? 120
        playCountBias = (try? c.decode(Bias.self, forKey: .playCountBias)) ?? .off
        favoriteBias = (try? c.decode(Bias.self, forKey: .favoriteBias)) ?? .off
        genreCategories = (try? c.decode(Set<String>.self, forKey: .genreCategories)) ?? []
        yearMin = try? c.decode(Int.self, forKey: .yearMin)
        yearMax = try? c.decode(Int.self, forKey: .yearMax)
        membershipMode = (try? c.decode(MembershipMode.self, forKey: .membershipMode)) ?? .off
        membershipCollectionIds = (try? c.decode(Set<String>.self, forKey: .membershipCollectionIds)) ?? []
        targetCollectionIds = (try? c.decode([String].self, forKey: .targetCollectionIds)) ?? []
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
        return parts.joined(separator: " · ")
    }
}
