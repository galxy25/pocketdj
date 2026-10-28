package com.levi.pocketdj.data.config

/**
 * Endpoint constants for the shared PocketDJ backend (specs/catalog.md §1,
 * specs/playback.md §1, specs/browse.md §1).
 *
 * Dev and prod ride different CloudFront distributions; Android P1 ships pinned
 * at prod, but both live here so a future environment switch is a one-line change.
 */
object Endpoints {
    // Account-bound bases are read LIVE from [RemoteEndpoints] (docs/design/remote-endpoints.md)
    // at request time, so a blue ↔ green backend flip needs no release. Compiled-in defaults =
    // today's green values (EndpointConfig.COMPILED_IN).
    val CATALOG_BASE_PROD: String get() = RemoteEndpoints.url(EndpointKey.CATALOG_BASE)
    val CATALOG_BASE_DEV: String get() = RemoteEndpoints.url(EndpointKey.CATALOG_BASE_DEV)

    /** The base every catalog-relative URL resolves against. Android P1 = prod. */
    val CATALOG_BASE: String get() = CATALOG_BASE_PROD

    // Per-source index documents (exact source-name strings are load-bearing:
    // they match the iOS Settings presets, catalog.md §1).
    const val SOURCE_NAME_VINYL = "My Vinyl"
    const val SOURCE_NAME_APPLE_MUSIC = "Apple Music (Local)"
    const val SOURCE_NAME_DIGITAL = "My Digital"

    val VINYL_INDEX_URL: String get() = "$CATALOG_BASE/current-index.json"
    val APPLE_MUSIC_INDEX_URL: String get() = "$CATALOG_BASE/apple-music-index.json"
    val DIGITAL_INDEX_URL: String get() = "$CATALOG_BASE/digital-index.json"

    /** Online-search host config — read at launch so the aoss host can rotate. */
    val SEARCH_CONFIG_URL: String get() = RemoteEndpoints.url(EndpointKey.SEARCH_CONFIG_URL)

    /** Favorites seed — not Phase 1, recorded for later phases. */
    val FAVORITES_SEED_URL: String get() = "$CATALOG_BASE/favorites-seed.json"

    /** Public rips bucket — public-read, works with the rip server offline. */
    val RIPS_BASE: String get() = RemoteEndpoints.url(EndpointKey.RIPS_BASE)
    val RIPS_MANIFEST_URL: String get() = "$RIPS_BASE/rips/manifest.json"

    /** Instrument-pack manifest (STU-8): `rips/instruments/index.json` under the rips bucket. */
    val INSTRUMENTS_INDEX_URL: String get() = "$RIPS_BASE/rips/instruments/index.json"

    /**
     * Base the manifest's RELATIVE bank keys (`banks/<file>.sf2`) append to. The client never invents
     * S3 paths and never uses an absolute bankKey (a bare bucket-root key 403s).
     */
    val INSTRUMENTS_BASE: String get() = "$RIPS_BASE/rips/instruments"

    /** `instrumentsBase + "/" + key` (a leading slash on [key] is dropped). */
    fun instrumentBankUrl(key: String): String = "$INSTRUMENTS_BASE/${key.removePrefix("/")}"

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
