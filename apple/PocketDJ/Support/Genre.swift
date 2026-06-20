import Foundation

/// Genre → top-tier category mapping, ported from the PWA's two-tier star map
/// (`src/starmap/constellationMap.ts`). The Browser's genre filter collapses raw
/// album genres into these categories so the user sees exactly the same genre
/// list the PWA's mobile constellation grid shows.
///
/// Pure, ordered substring matcher (NOT a fixed lookup): iterate categories in
/// priority order; the first whose ANY keyword is a substring of the normalized
/// genre wins. Empty/unmappable → "Other".
enum Genre {
    static let other = "Other"

    /// Tier-1 categories in priority order (specific leaf genres first; broad
    /// parent tags like funk/soul/r&b/rock/pop last) with their routing keywords.
    static let categories: [(name: String, keywords: [String])] = [
        ("hip-hop", ["hip hop", "hip-hop", "hiphop", "rap", "boom bap", "gangsta", "g-funk", "crunk",
                     "trap", "conscious", "jazzy hip", "jazz rap", "plunderphonics", "dj battle",
                     "cut-up/dj", "ragga hiphop", "thug rap", "dance rap", "political rap",
                     "old-school hip", "new-school hip", "golden age", "underground hip",
                     "alternative hip", "instrumental hip", "east coast", "west coast", "southern hip"]),
        ("classical", ["classical", "baroque", "romantic", "symphonic", "orchestral", "chamber",
                       "opera", "film music", "wagnerian"]),
        ("blues", ["blues"]),
        ("country", ["country", "americana", "bluegrass", "outlaw", "nashville", "bakersfield",
                     "countrypolitan", "western", "ranchera", "mariachi", "norteño", "norteno", "honky"]),
        ("world", ["latin", "salsa", "merengue", "cumbia", "charanga", "bolero", "samba", "guajira",
                   "marimba", "andean", "bossa", "reggae", "dancehall", "ragga", "ska", "afro",
                   "polka", "hawaiian", "indian classical", "hindustani", "world"]),
        ("jazz", ["jazz", "bossa nova", "big band", "bebop", "cool jazz", "smooth jazz", "post-bop",
                  "vocal jazz", "fusion", "crossover jazz", "acid jazz", "soul-jazz"]),
        ("disco", ["disco", "boogie", "hi nrg", "hi-nrg", "hinrg", "post-disco", "nu-disco",
                   "eurodance", "freestyle", "go-go"]),
        ("funk", ["funk", "minneapolis", "p-funk", "avant-funk", "jazz-funk", "jazz funk", "acid jazz",
                  "synth-funk", "quiet storm", "go-go"]),
        ("soul", ["soul", "motown", "philly soul", "philadelphia soul", "gospel", "doo wop",
                  "doo-wop", "quiet storm"]),
        ("r&b", ["r&b", "rnb", "rhythm & blues", "rhythm and blues", "new jack", "contemporary r&b",
                 "hip-hop soul", "hip hop soul", "urban", "minneapolis sound"]),
        ("electronic", ["electronic", "electronica", "house", "techno", "trance", "edm", "synth-pop",
                        "synthpop", "synth pop", "electropop", "electro", "downtempo", "trip hop",
                        "leftfield", "new wave", "breaks", "tribal house", "deep house",
                        "progressive house", "witch house", "darkwave", "indietronica", "bass music",
                        "dub", "hi nrg"]),
        ("rock", ["rock", "metal", "punk", "grunge", "psychedelic", "garage", "shoegaze", "indie rock",
                  "glam", "arena", "heartland", "thrash"]),
        ("folk", ["folk", "singer-songwriter", "indie folk", "folk rock", "folk-pop", "folk jazz",
                  "sunshine pop", "spoken word", "poetry"]),
        ("pop", ["pop", "dance-pop", "dance pop", "dance-rock", "art pop", "baroque pop", "chamber pop",
                 "sophisti-pop", "europop", "new pop", "traditional pop", "novelty", "comedy",
                 "adult contemporary", "dance"]),
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
        return other
    }

    /// Sort key for ordering categories in the canonical priority order.
    static func order(of category: String) -> Int {
        categoryNames.firstIndex(of: category) ?? categoryNames.count
    }
}
