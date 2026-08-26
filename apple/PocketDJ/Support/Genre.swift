import Foundation

/// Genre → top-tier category mapping. Originally ported from the PWA's two-tier star map
/// (`src/starmap/constellationMap.ts`); the ENGINE taxonomy has since extended past the star
/// map's — a `holiday` tier-1 and a broad-tag second pass — because a genre the star map merely
/// draws in its "Other" constellation is a genre the recommender scores with NOTHING. The star
/// map is a visualization taxonomy and is deliberately not carried along; this table and
/// `scripts/build-rec-features.mjs` are the scoring taxonomy and must stay identical.
///
/// The Browser's genre filter collapses raw album genres into these categories so the user sees
/// one consistent genre list.
///
/// Pure, ordered substring matcher (NOT a fixed lookup) run in TWO passes:
///   pass 1 — every category's `keywords`, in order: specific leaf genres.
///   pass 2 — every category's `broad` tags, in order: parent tags so broad they must lose to ANY
///            specific genre. "Alternative Folk" is folk; a bare "Alternative" is rock.
/// A pass-2 tag cannot simply be appended to pass 1: the table is first-hit-wins and rock sits
/// ahead of folk and pop, so 'alternative' in rock's pass-1 list would drag 58 "Alternative Folk"
/// and 15 "Indie, Pop, Alternative" rows out of the category they already resolve to correctly.
/// Empty/unmappable → "Other".
///
/// KEEP IN SYNC with scripts/build-rec-features.mjs (`genreCategory`): the recommendation
/// engine's feature builder ports this table + matcher verbatim, and it DROPS row.g entirely for
/// "Other" — so a label missing from this table costs the song its whole genre signal, not just
/// its label. tests/unit/genre-parity.test.mjs reads this file and fails if the two diverge.
enum Genre {
    static let other = "Other"

    /// Tier-1 categories in priority order (specific leaf genres first; broad
    /// parent tags like funk/soul/r&b/rock/pop last) with their routing keywords,
    /// plus the second-pass `broad` tags that only claim a label nothing else did.
    static let categories: [(name: String, keywords: [String], broad: [String])] = [
        // A seasonal tag is the most specific thing about a record and outranks its parent genre:
        // "Christmas: R&B" belongs with the other holiday songs, not with the rest of soul.
        ("holiday", ["holiday", "christmas", "xmas", "hanukkah", "kwanzaa", "yuletide", "halloween"], []),
        ("hip-hop", ["hip hop", "hip-hop", "hiphop", "rap", "boom bap", "gangsta", "g-funk", "crunk",
                     "trap", "conscious", "jazzy hip", "jazz rap", "plunderphonics", "dj battle",
                     "cut-up/dj", "ragga hiphop", "thug rap", "dance rap", "political rap",
                     "old-school hip", "new-school hip", "golden age", "underground hip",
                     "alternative hip", "instrumental hip", "east coast", "west coast", "southern hip",
                     "dirty south"], []),
        ("classical", ["classical", "baroque", "romantic", "symphonic", "orchestral", "chamber",
                       "opera", "film music", "wagnerian", "minimalism"],
                      // A soundtrack is whatever the film needed; only claim it when nothing else did.
                      ["soundtrack", "score", "musicals"]),
        ("blues", ["blues", "jug band"], []),
        ("country", ["country", "americana", "bluegrass", "outlaw", "nashville", "bakersfield",
                     "countrypolitan", "western", "ranchera", "mariachi", "norteño", "norteno", "honky"], []),
        // "asia", "france", "farsi", "arabic" are Apple Music's REGIONAL buckets, which arrive as
        // the whole genre string for imported rows; they carry no other meaning in this catalog.
        ("world", ["latin", "salsa", "merengue", "cumbia", "charanga", "bolero", "samba", "guajira",
                   "marimba", "andean", "bossa", "reggae", "dancehall", "ragga", "ska", "afro",
                   "polka", "hawaiian", "indian classical", "hindustani", "world", "african",
                   "música tropical", "musica tropical", "música mexicana", "musica mexicana",
                   "brazilian", "mpb", "amapiano", "kizomba", "highlife", "celtic", "caribbean",
                   "exotica", "jùjú", "juju", "regional indian", "asia", "france", "farsi", "arabic"], []),
        ("jazz", ["jazz", "bossa nova", "big band", "bebop", "cool jazz", "smooth jazz", "post-bop",
                  "vocal jazz", "fusion", "crossover jazz", "acid jazz", "soul-jazz", "bop"], []),
        ("disco", ["disco", "boogie", "hi nrg", "hi-nrg", "hinrg", "post-disco", "nu-disco",
                   "eurodance", "freestyle", "go-go"], []),
        ("funk", ["funk", "minneapolis", "p-funk", "avant-funk", "jazz-funk", "jazz funk", "acid jazz",
                  "synth-funk", "quiet storm", "go-go"], []),
        ("soul", ["soul", "motown", "philly soul", "philadelphia soul", "gospel", "doo wop",
                  "doo-wop", "quiet storm"],
                 // Sits with gospel — but Christian ROCK is rock, so it only claims what nothing else did.
                 ["christian", "religious"]),
        ("r&b", ["r&b", "rnb", "rhythm & blues", "rhythm and blues", "new jack", "contemporary r&b",
                 "hip-hop soul", "hip hop soul", "urban", "minneapolis sound"], []),
        ("electronic", ["electronic", "electronica", "house", "techno", "trance", "edm", "synth-pop",
                        "synthpop", "synth pop", "electropop", "electro", "downtempo", "trip hop",
                        "leftfield", "new wave", "breaks", "tribal house", "deep house",
                        "progressive house", "witch house", "darkwave", "indietronica", "bass music",
                        "dub", "hi nrg", "breakbeat", "jungle", "drum'n'bass", "drum and bass"],
                       ["ambient", "idm", "experimental", "new age", "bass"]),
        ("rock", ["rock", "metal", "punk", "grunge", "psychedelic", "garage", "shoegaze", "indie rock",
                  "glam", "arena", "heartland", "thrash"],
                 // The catalog's single biggest dropped label ("Alternative", 6,341 rows) lives here.
                 ["alternative", "indie", "hardcore"]),
        ("folk", ["folk", "singer-songwriter", "singer/songwriter", "singer songwriter", "indie folk",
                  "folk rock", "folk-pop", "folk jazz", "sunshine pop", "spoken word", "poetry"], []),
        ("pop", ["pop", "dance-pop", "dance pop", "dance-rock", "art pop", "baroque pop", "chamber pop",
                 "sophisti-pop", "europop", "new pop", "traditional pop", "novelty", "comedy",
                 "adult contemporary", "dance", "easy listening", "children", "oldies", "lounge",
                 "vocal"], []),
    ]

    /// All category names in display/priority order, with "Other" appended last.
    static let categoryNames: [String] = categories.map(\.name) + [other]

    private static let cssBlob = try? NSRegularExpression(pattern: #"\.mw-parser-output[^}]*\}"#)

    /// Map a raw genre string to its tier-1 category (first keyword hit wins).
    static func category(_ genre: String?) -> String {
        guard let genre else { return other }
        var s = genre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return other }
        if let cssBlob {
            s = cssBlob.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.isEmpty { return other }
        for cat in categories where cat.keywords.contains(where: { s.contains($0) }) {
            return cat.name
        }
        for cat in categories where cat.broad.contains(where: { s.contains($0) }) {
            return cat.name
        }
        return other
    }

    /// Sort key for ordering categories in the canonical priority order.
    static func order(of category: String) -> Int {
        categoryNames.firstIndex(of: category) ?? categoryNames.count
    }
}
