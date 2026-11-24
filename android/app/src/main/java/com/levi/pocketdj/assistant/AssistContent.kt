package com.levi.pocketdj.assistant

/**
 * On-screen context for the system assistant (iOS `NowPlayingSiriContext` analogue). While Now
 * Playing is visible, `MainActivity.onProvideAssistContent` hands the assistant a schema.org
 * `MusicRecording` JSON-LD description plus a web URI. Pure builders live here so they are
 * JVM-testable; the activity only wires them.
 */
object AssistContent {
    /** Shared with the shell: the current nav route. Visibility is derived at assist time. */
    @Volatile var currentRoute: String? = null

    /** True while [nowPlayingRoute] is the visible destination. */
    fun isNowPlayingVisible(route: String? = currentRoute, nowPlayingRoute: String): Boolean =
        route != null && route == nowPlayingRoute

    /** Website fallback URI (the assistant needs a web URI to attribute the content to). */
    const val WEB_URI = "https://pocket-dj.com/"

    /** schema.org `MusicRecording` for [title] by [artist]; null when there is no title to describe. */
    fun musicRecordingJsonLd(title: String?, artist: String?): String? {
        val t = title?.trim().orEmpty()
        if (t.isEmpty()) return null
        val a = artist?.trim().orEmpty()
        val sb = StringBuilder("{\"@context\":\"https://schema.org\",\"@type\":\"MusicRecording\",\"name\":")
        sb.append(quote(t))
        if (a.isNotEmpty()) {
            sb.append(",\"byArtist\":{\"@type\":\"MusicGroup\",\"name\":").append(quote(a)).append('}')
        }
        return sb.append('}').toString()
    }

    /**
     * The JSON-LD to attach right now, or null (nothing to attach) unless Now Playing is
     * [visible] and a song is loaded.
     */
    fun forNowPlaying(visible: Boolean, title: String?, artist: String?): String? =
        if (!visible) null else musicRecordingJsonLd(title, artist)

    /** JSON string literal with RFC 8259 escaping. */
    internal fun quote(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c == '\n' -> sb.append("\\n")
                c == '\r' -> sb.append("\\r")
                c == '\t' -> sb.append("\\t")
                c < ' ' -> sb.append(String.format("\\u%04x", c.code))
                else -> sb.append(c)
            }
        }
        return sb.append('"').toString()
    }
}

/** Query extraction for the Assistant "search PocketDJ for…" intents. */
object SearchActionQuery {
    const val GMS_SEARCH_ACTION = "com.google.android.gms.actions.SEARCH_ACTION"
    const val MEDIA_SEARCH = "android.intent.action.MEDIA_SEARCH"

    /** Both actions carry the text in the `query` extra (SearchManager.QUERY); blank -> null. */
    fun parse(action: String?, extra: (String) -> String?): String? {
        if (action != GMS_SEARCH_ACTION && action != MEDIA_SEARCH) return null
        return extra("query")?.trim()?.takeIf { it.isNotEmpty() }
    }
}
