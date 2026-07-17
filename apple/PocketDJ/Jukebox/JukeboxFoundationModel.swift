import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Builds the on-device pick model for the Jukebox request matcher, or nil when Apple
/// Intelligence can't run here (OS gate / device / not enabled / not ready). Mirrors
/// `PocketBriefModelFactory`, but returns nil instead of throwing: the jukebox degrades
/// gracefully to the top fuzzy candidate — a party must not stop for a model download.
enum JukeboxPickModelFactory {
    @MainActor
    static func make() -> (any JukeboxPickModel)? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return FoundationJukeboxPickModel()
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)

/// One guided-generation call per request: the numbered candidate rows + the guest's
/// text, out comes a candidate number (0 = none of these is the requested song). Same
/// budget doctrine as `FoundationPocketBriefModel`: a fresh 4,096-token session per
/// call, rows numbered so the model copies a small int instead of a long id.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct FoundationJukeboxPickModel: JukeboxPickModel {

    @Generable(description: "Which numbered candidate is the requested song")
    struct Pick {
        @Guide(description: "The number of the candidate that is the requested song, or 0 if none of them is that song")
        var candidateNumber: Int
    }

    func pick(title: String, artist: String, candidates: [JukeboxPickCandidate]) async throws -> Int? {
        guard !candidates.isEmpty else { return nil }
        let rows = candidates.enumerated().map { (i, c) -> String in
            let year = c.year.map(String.init) ?? "-"
            return "\(i + 1)|\(c.title)|\(c.artist)|\(year)"
        }
        let session = LanguageModelSession(instructions: """
            You match a party guest's song request to a DJ's music catalog. The prompt \
            gives the requested song title and artist, then numbered candidate songs, one \
            per line, as number|title|artist|year. Answer with the number of the candidate \
            that is the same song the guest asked for — cover versions, remasters, and \
            live editions of it count as the same song. Answer 0 only when none of the \
            candidates is that song.
            """)
        let prompt = "Requested: \(title) — \(artist.isEmpty ? "unknown artist" : artist)\n\nCandidates:\n\(rows.joined(separator: "\n"))"
        let response = try await session.respond(to: prompt, generating: Pick.self)
        let n = response.content.candidateNumber
        return n == 0 ? nil : n
    }
}

#endif
