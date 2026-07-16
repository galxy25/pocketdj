import Foundation

// The Jukebox "DJ brain": a guest's free-text (title, artist) request → the best playable
// match. Pipeline (docs/design/jukebox-hero.md):
//   1. SWIFT  normalized-exact match against the catalog (ShazamCatalogMatch.norm — the
//             canonical normalizer, so "Café (Remastered)" noise never blocks a hit)
//   2. SWIFT  fuzzy candidate ranking over the whole catalog (pure, testable)
//   3. MODEL  on-device Foundation Models pick over the numbered candidates (protocol
//             seam — tests stub it; graceful fallback to the top candidate without it)
//   4. MUSIC  Apple Music catalog search for songs we don't have at all — mapped back to
//             the catalog when possible, else an Apple-Music-only match (`am:<storeID>`)
// The HOST stays the judge: every match is shown beside the request in the inbox, and
// deny is always one tap away — so the matcher optimizes for a good first guess, not
// for certainty.

/// Where a guest request landed.
enum JukeboxMatch: Equatable {
    /// A song in the loaded catalog — plays through the normal provider chain
    /// (burned file / Apple Music stream / rip-server stream, all existing paths).
    case catalog(IndexSong)
    /// Not in the catalog, but found in the Apple Music catalog — streams via MusicKit
    /// under the namespaced `am:<storeID>` id (the coordinator resolves it directly).
    case appleMusic(storeID: String, title: String, artist: String)
    /// Nothing matched — the host can only deny (or the guest can rephrase).
    case none
}

/// One numbered candidate row shown to the pick model.
struct JukeboxPickCandidate: Equatable, Sendable {
    let title: String
    let artist: String
    let year: Int?
    let genre: String?
}

/// The single LLM call, abstracted for testability + OS-availability isolation
/// (the `PocketBriefModel` doctrine). Returns the 1-based number of the candidate
/// that IS the requested song, or nil when none of them is.
protocol JukeboxPickModel: Sendable {
    func pick(title: String, artist: String, candidates: [JukeboxPickCandidate]) async throws -> Int?
}

// MARK: - Pure matching (exact + fuzzy ranking)

enum JukeboxMatching {

    /// Step 1 — normalized-exact: title equal + artist compatible (containment either
    /// way), via the canonical `ShazamCatalogMatch` matcher. First catalog hit wins.
    static func exact(title: String, artist: String, in songs: [IndexSong]) -> IndexSong? {
        let info = ShazamHitInfo(title: title, artist: artist.isEmpty ? nil : artist,
                                 artworkURL: nil, appleMusicID: nil)
        if case .inCatalog(let song, _) = ShazamCatalogMatch.resolve(info, in: songs) { return song }
        return nil
    }

    static let candidateCap = 20

    /// Step 2 — fuzzy candidates: fold + tokenize the request and score every song by
    /// title-token and artist-token coverage. At least one TITLE token must hit (a
    /// guest's artist field alone must not drag in that artist's whole discography);
    /// title coverage outweighs artist coverage; a normalized-title equality wins the
    /// tie. Pure + nonisolated — callers feed it snapshot arrays off the main actor
    /// (the ~100k-catalog NowPlayingSearch doctrine).
    static func candidates(title: String, artist: String,
                           in songs: [IndexSong], cap: Int = candidateCap) -> [IndexSong] {
        let nTitle = ShazamCatalogMatch.norm(title)
        let nArtist = ShazamCatalogMatch.norm(artist)
        let titleTokens = nTitle.split(separator: " ").map(String.init)
        let artistTokens = nArtist.split(separator: " ").map(String.init)
        guard !titleTokens.isEmpty else { return [] }

        struct Scored { let song: IndexSong; let score: Double; let order: Int }
        var scored: [Scored] = []
        for (i, song) in songs.enumerated() {
            let sTitle = ShazamCatalogMatch.norm(song.name)
            let titleHits = titleTokens.filter { sTitle.contains($0) }.count
            guard titleHits > 0 else { continue }
            var score = 2.0 * Double(titleHits) / Double(titleTokens.count)
            if !artistTokens.isEmpty {
                let sArtist = ShazamCatalogMatch.norm(song.artist)
                let artistHits = artistTokens.filter { sArtist.contains($0) }.count
                score += Double(artistHits) / Double(artistTokens.count)
            }
            if sTitle == nTitle { score += 1 }   // exact title beats superset titles
            scored.append(Scored(song: song, score: score, order: i))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(cap)
            .map(\.song)
    }
}

// MARK: - The matcher (orchestrates the 4 steps)

/// Built by `JukeboxStore` with the live seams: the FM pick model (nil when Apple
/// Intelligence is unavailable — the top fuzzy candidate stands in) and the Apple Music
/// catalog search (nil when the account isn't linked — the pipeline stops at the catalog).
@MainActor
struct JukeboxMatcher {
    var model: (any JukeboxPickModel)?
    /// Apple Music catalog search seam (`AppleMusicProvider.search`); nil ⇒ skipped.
    var searchAppleMusic: ((String) async -> [StreamingTrack])?

    func match(title: String, artist: String, app: AppModel) async -> JukeboxMatch {
        let songs = app.songs   // value snapshot (main actor); scans run detached
        let (exactHit, fuzzy) = await Task.detached(priority: .userInitiated) {
            (JukeboxMatching.exact(title: title, artist: artist, in: songs),
             JukeboxMatching.candidates(title: title, artist: artist, in: songs))
        }.value
        if let exactHit { return .catalog(exactHit) }

        if !fuzzy.isEmpty {
            if let model {
                let rows = fuzzy.map {
                    JukeboxPickCandidate(title: $0.name, artist: $0.artist,
                                         year: $0.year, genre: nil)
                }
                do {
                    if let n = try await model.pick(title: title, artist: artist, candidates: rows),
                       (1...fuzzy.count).contains(n) {
                        return .catalog(fuzzy[n - 1])
                    }
                    // The model says none of our candidates IS the song → try Apple Music.
                } catch {
                    return .catalog(fuzzy[0])   // model errored — top candidate stands in
                }
            } else {
                return .catalog(fuzzy[0])       // no Apple Intelligence — same fallback
            }
        }

        // Step 4 — not in the catalog (or the model rejected every candidate): search the
        // Apple Music catalog. A hit may still map BACK to an indexed song (by store id /
        // appleMusicId / normalized title+artist); otherwise it's an AM-only match.
        if let searchAppleMusic {
            let term = artist.isEmpty ? title : "\(title) \(artist)"
            if let track = await searchAppleMusic(term).first {
                let storeID = track.providerTrackID
                if let indexed = AppleMusicRecognition.indexSong(
                    storeID: storeID, title: track.title, artist: track.artist, in: songs) {
                    return .catalog(indexed)
                }
                return .appleMusic(storeID: storeID, title: track.title,
                                   artist: track.artist ?? artist)
            }
        }
        return .none
    }
}
