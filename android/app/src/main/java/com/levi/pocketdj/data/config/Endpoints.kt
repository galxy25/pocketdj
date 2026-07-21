package com.levi.pocketdj.data.config

/**
 * Endpoint constants for the shared PocketDJ backend (specs/catalog.md §1,
 * specs/playback.md §1, specs/browse.md §1).
 *
 * Dev and prod ride different CloudFront distributions; Android P1 ships pinned
 * at prod, but both live here so a future environment switch is a one-line change.
 */
object Endpoints {
    const val CATALOG_BASE_PROD = "https://d2p4cubg6se03u.cloudfront.net"
    const val CATALOG_BASE_DEV = "https://djictbz9w796r.cloudfront.net"

    /** The base every catalog-relative URL resolves against. Android P1 = prod. */
    const val CATALOG_BASE = CATALOG_BASE_PROD

    // Per-source index documents (exact source-name strings are load-bearing:
    // they match the iOS Settings presets, catalog.md §1).
    const val SOURCE_NAME_VINYL = "My Vinyl"
    const val SOURCE_NAME_APPLE_MUSIC = "Apple Music (Local)"
    const val SOURCE_NAME_DIGITAL = "My Digital"

    const val VINYL_INDEX_URL = "$CATALOG_BASE/current-index.json"
    const val APPLE_MUSIC_INDEX_URL = "$CATALOG_BASE/apple-music-index.json"
    const val DIGITAL_INDEX_URL = "$CATALOG_BASE/digital-index.json"

    /** Online-search host config — read at launch so the aoss host can rotate. */
    const val SEARCH_CONFIG_URL = "$CATALOG_BASE/search-config.json"

    /** Favorites seed — not Phase 1, recorded for later phases. */
    const val FAVORITES_SEED_URL = "$CATALOG_BASE/favorites-seed.json"

    /** Public rips bucket — public-read, works with the rip server offline. */
    const val RIPS_BASE = "https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com"
    const val RIPS_MANIFEST_URL = "$RIPS_BASE/rips/manifest.json"

    /**
     * Rip server: NO shipped default — the user pastes their own (Tailscale
     * Funnel) URL into Settings; empty means every server feature is dormant
     * (playback.md §1).
     */
    const val DEFAULT_RIP_SERVER_URL = ""

    /**
     * Jukebox broker base URL: also blank by default, user-entered in Settings
     * (jukebox.md §2.1, §6). The canonical deployment is a Funnel path mount
     * ending in /jukebox, but the client never derives or bakes it.
     */
    const val DEFAULT_JUKEBOX_SERVER_URL = ""

    /**
     * Art URL resolution (catalog.md §1): root-relative ("/art/…") resolves
     * against [CATALOG_BASE]; absolute URLs are used as-is.
     */
    fun artUrl(raw: String): String = if (raw.startsWith("/")) CATALOG_BASE + raw else raw

    /** Lyrics text for a song — fetch ONLY when `lyricsStatus == "found"`. */
    fun lyricsUrl(songId: String): String = "$CATALOG_BASE/lyrics/$songId.txt"

    /** Playable audio for a rips-manifest entry key (e.g. "rips/<id>.mp3"). */
    fun ripAudioUrl(key: String): String = "$RIPS_BASE/${key.removePrefix("/")}"
}
