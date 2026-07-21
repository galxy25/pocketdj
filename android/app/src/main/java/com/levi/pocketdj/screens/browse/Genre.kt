package com.levi.pocketdj.screens.browse

/**
 * Genre → top-tier category mapping, ported verbatim from
 * `apple/PocketDJ/Support/Genre.swift` (specs/browse.md §5 — "port the keyword
 * table verbatim").
 *
 * Pure, ordered substring matcher (NOT a fixed lookup): iterate categories in
 * priority order; the first whose ANY keyword is a substring of the normalized
 * genre wins. Empty/unmappable → "Other".
 */
object Genre {
    const val OTHER = "Other"

    /**
     * Tier-1 categories in priority order (specific leaf genres first; broad
     * parent tags like funk/soul/r&b/rock/pop last) with their routing keywords.
     */
    val categories: List<Pair<String, List<String>>> = listOf(
        "hip-hop" to listOf(
            "hip hop", "hip-hop", "hiphop", "rap", "boom bap", "gangsta", "g-funk", "crunk",
            "trap", "conscious", "jazzy hip", "jazz rap", "plunderphonics", "dj battle",
            "cut-up/dj", "ragga hiphop", "thug rap", "dance rap", "political rap",
            "old-school hip", "new-school hip", "golden age", "underground hip",
            "alternative hip", "instrumental hip", "east coast", "west coast", "southern hip",
        ),
        "classical" to listOf(
            "classical", "baroque", "romantic", "symphonic", "orchestral", "chamber",
            "opera", "film music", "wagnerian",
        ),
        "blues" to listOf("blues"),
        "country" to listOf(
            "country", "americana", "bluegrass", "outlaw", "nashville", "bakersfield",
            "countrypolitan", "western", "ranchera", "mariachi", "norteño", "norteno", "honky",
        ),
        "world" to listOf(
            "latin", "salsa", "merengue", "cumbia", "charanga", "bolero", "samba", "guajira",
            "marimba", "andean", "bossa", "reggae", "dancehall", "ragga", "ska", "afro",
            "polka", "hawaiian", "indian classical", "hindustani", "world",
        ),
        "jazz" to listOf(
            "jazz", "bossa nova", "big band", "bebop", "cool jazz", "smooth jazz", "post-bop",
            "vocal jazz", "fusion", "crossover jazz", "acid jazz", "soul-jazz",
        ),
        "disco" to listOf(
            "disco", "boogie", "hi nrg", "hi-nrg", "hinrg", "post-disco", "nu-disco",
            "eurodance", "freestyle", "go-go",
        ),
        "funk" to listOf(
            "funk", "minneapolis", "p-funk", "avant-funk", "jazz-funk", "jazz funk", "acid jazz",
            "synth-funk", "quiet storm", "go-go",
        ),
        "soul" to listOf(
            "soul", "motown", "philly soul", "philadelphia soul", "gospel", "doo wop",
            "doo-wop", "quiet storm",
        ),
        "r&b" to listOf(
            "r&b", "rnb", "rhythm & blues", "rhythm and blues", "new jack", "contemporary r&b",
            "hip-hop soul", "hip hop soul", "urban", "minneapolis sound",
        ),
        "electronic" to listOf(
            "electronic", "electronica", "house", "techno", "trance", "edm", "synth-pop",
            "synthpop", "synth pop", "electropop", "electro", "downtempo", "trip hop",
            "leftfield", "new wave", "breaks", "tribal house", "deep house",
            "progressive house", "witch house", "darkwave", "indietronica", "bass music",
            "dub", "hi nrg",
        ),
        "rock" to listOf(
            "rock", "metal", "punk", "grunge", "psychedelic", "garage", "shoegaze", "indie rock",
            "glam", "arena", "heartland", "thrash",
        ),
        "folk" to listOf(
            "folk", "singer-songwriter", "indie folk", "folk rock", "folk-pop", "folk jazz",
            "sunshine pop", "spoken word", "poetry",
        ),
        "pop" to listOf(
            "pop", "dance-pop", "dance pop", "dance-rock", "art pop", "baroque pop", "chamber pop",
            "sophisti-pop", "europop", "new pop", "traditional pop", "novelty", "comedy",
            "adult contemporary", "dance",
        ),
    )

    /** All category names in display/priority order, with "Other" appended last. */
    val categoryNames: List<String> = categories.map { it.first } + OTHER

    /** Wikipedia-scrape artifact stripped before matching (mirrors iOS). */
    private val cssBlob = Regex("""\.mw-parser-output[^}]*\}""")

    /** Map a raw genre string to its tier-1 category (first keyword hit wins). */
    fun category(genre: String?): String {
        if (genre == null) return OTHER
        var s = genre.lowercase().trim()
        if (s.isEmpty()) return OTHER
        s = cssBlob.replace(s, " ").trim()
        if (s.isEmpty()) return OTHER
        for ((name, keywords) in categories) {
            if (keywords.any { s.contains(it) }) return name
        }
        return OTHER
    }

    /** Sort key for ordering categories in the canonical priority order. */
    fun order(category: String): Int {
        val index = categoryNames.indexOf(category)
        return if (index >= 0) index else categoryNames.size
    }
}
