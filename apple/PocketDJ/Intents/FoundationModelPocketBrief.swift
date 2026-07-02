import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Builds the LLM client for the Create-Pocket pipeline, or throws a speakable
/// reason. The ONLY place that knows about FoundationModels' OS gate (iOS 26 /
/// macOS 26 — the app deploys to iOS 18 / macOS 15, so everything is #available-
/// scoped and the framework auto-weak-links).
enum PocketBriefModelFactory {
    @MainActor
    static func make() throws -> any PocketBriefModel {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw PocketDJIntentError.intelligenceUnavailable(
                "Creating pockets needs iOS 26 or macOS 26 with Apple Intelligence.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationPocketBriefModel()
        case .unavailable(.deviceNotEligible):
            throw PocketDJIntentError.intelligenceUnavailable(
                "This device can't run Apple Intelligence, which PocketDJ uses to build pockets.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw PocketDJIntentError.intelligenceUnavailable(
                "Turn on Apple Intelligence in Settings so PocketDJ can build pockets.")
        case .unavailable(.modelNotReady):
            throw PocketDJIntentError.intelligenceUnavailable(
                "Apple Intelligence is still getting ready — try again in a bit.")
        case .unavailable:
            throw PocketDJIntentError.intelligenceUnavailable(
                "Apple Intelligence isn't available right now.")
        }
        #else
        throw PocketDJIntentError.intelligenceUnavailable(
            "Creating pockets needs iOS 26 or macOS 26 with Apple Intelligence.")
        #endif
    }
}

#if canImport(FoundationModels)

/// The on-device Apple Foundation model behind the Create-Pocket pipeline. Two
/// SEPARATE sessions (parse, then curate) — each session is a fresh 4,096-token
/// window, and the candidate block (~80 rows × ~25 tokens) plus instructions and
/// the guided-output schema must fit inside the second one. Guided generation
/// (`@Generable`) makes the outputs schema-valid by construction — no JSON parsing.
@available(iOS 26.0, macOS 26.0, *)
struct FoundationPocketBriefModel: PocketBriefModel {

    @Generable(description: "Music filters extracted from a listener's playlist brief")
    struct BriefFilters {
        @Guide(description: "Mood or feeling words implied by the brief, e.g. optimistic, melancholy, high-energy", .maximumCount(6))
        var moods: [String]
        @Guide(description: "Music genres named or clearly implied, e.g. soul, funk, disco", .maximumCount(6))
        var genres: [String]
        @Guide(description: "Earliest release year, only if the brief limits years")
        var yearFrom: Int?
        @Guide(description: "Latest release year, only if the brief limits years")
        var yearTo: Int?
    }

    @Generable(description: "A curated DJ pocket picked from the numbered candidate songs")
    struct Plan {
        @Guide(description: "A short, evocative pocket title of two to four words")
        var name: String
        @Guide(description: "The number of each chosen candidate song, in play order", .minimumCount(1), .maximumCount(40))
        var songNumbers: [Int]
    }

    func parse(brief: String) async throws -> ParsedPocketBrief {
        let session = LanguageModelSession(instructions: """
            You extract structured music-search filters from a listener's brief for a DJ app. \
            Only extract what the brief actually says or strongly implies; leave year \
            bounds empty unless the brief limits years.
            """)
        let response = try await session.respond(to: brief, generating: BriefFilters.self)
        let f = response.content
        return ParsedPocketBrief(moods: f.moods, genres: f.genres,
                                 yearFrom: f.yearFrom, yearTo: f.yearTo)
    }

    /// The session window is 4,096 tokens TOTAL (instructions + schema + prompt +
    /// output), so the candidate block is budgeted by characters (~3.5 chars/token):
    /// ~6,500 chars ≈ ~1,900 tokens, leaving room for everything else. Rows are
    /// NUMBERED and carry no catalog id — numbers are cheap for a small model to
    /// copy exactly; the long content-derived ids are mapped back here.
    static let candidateCharBudget = 6_500

    func curate(brief: String, candidates: [PocketCandidate], maxSongs: Int) async throws -> PocketPlan {
        var rows: [String] = []
        var shown: [PocketCandidate] = []
        var chars = 0
        for candidate in candidates {
            let secs = (candidate.lengthMs ?? PocketFitter.fallbackLengthMs) / 1000
            let row = [String(rows.count + 1), candidate.title, candidate.artist,
                       candidate.genre ?? "-", candidate.year.map(String.init) ?? "-",
                       "\(secs)s", candidate.moods.prefix(4).joined(separator: ",")]
                .joined(separator: "|")
            if chars + row.count > Self.candidateCharBudget { break }
            chars += row.count + 1
            rows.append(row)
            shown.append(candidate)
        }
        let session = LanguageModelSession(instructions: """
            You are a crate-digging DJ curating a "pocket" (a small themed crate) for the \
            listener's brief. The prompt lists numbered candidate songs, one per line, as \
            number|title|artist|genre|year|length|mood keywords. Choose the songs that \
            best fit the brief's vibe and order them to flow well back-to-back. Pick at \
            most \(maxSongs) songs, referring to each by its number. Also invent a short \
            evocative pocket title.
            """)
        let prompt = "Brief: \(brief)\n\nCandidates:\n\(rows.joined(separator: "\n"))"
        let response = try await session.respond(to: prompt, generating: Plan.self)
        let ids = response.content.songNumbers
            .filter { (1...shown.count).contains($0) }
            .map { shown[$0 - 1].id }
        return PocketPlan(name: response.content.name, songIds: ids)
    }
}

#endif
