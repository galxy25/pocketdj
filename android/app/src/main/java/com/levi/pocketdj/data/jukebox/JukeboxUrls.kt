package com.levi.pocketdj.data.jukebox

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Pure URL construction for the jukebox broker (specs/jukebox.md §2.1) —
 * separated from the client so the exact strings are unit-testable.
 *
 * Contract: trim whitespace and ONE trailing `/` from the configured base, then
 * append paths that always carry a leading `jukebox` segment for session
 * routes. This works both direct (`http://host:8788`) and behind a Tailscale
 * Funnel path mount (`https://…/jukebox`) because the server strips one leading
 * `/jukebox` segment before dispatch — never double-strip or special-case.
 * Path segments are percent-encoded via HttpUrl.
 */
object JukeboxUrls {

    fun normalizedBase(raw: String): String = raw.trim().removeSuffix("/")

    /** `GET {base}/health` */
    fun health(base: String): HttpUrl? = root(base)?.addPathSegment("health")?.build()

    /** `POST {base}/jukebox` — create a session. */
    fun create(base: String): HttpUrl? = root(base)?.addPathSegment("jukebox")?.build()

    /** `POST {base}/jukebox/{id}/state` */
    fun state(base: String, jukeboxId: String): HttpUrl? = session(base, jukeboxId, "state")

    /** `GET {base}/jukebox/{id}/requests?since={seq}` */
    fun requests(base: String, jukeboxId: String, since: Long): HttpUrl? =
        sessionBuilder(base, jukeboxId)
            ?.addPathSegment("requests")
            ?.addQueryParameter("since", since.toString())
            ?.build()

    /** `POST {base}/jukebox/{id}/requests/{reqId}/decision` */
    fun decision(base: String, jukeboxId: String, requestId: String): HttpUrl? =
        sessionBuilder(base, jukeboxId)
            ?.addPathSegment("requests")
            ?.addPathSegment(requestId)
            ?.addPathSegment("decision")
            ?.build()

    /** `POST {base}/jukebox/{id}/end` */
    fun end(base: String, jukeboxId: String): HttpUrl? = session(base, jukeboxId, "end")

    private fun root(base: String): HttpUrl.Builder? =
        normalizedBase(base).toHttpUrlOrNull()?.newBuilder()

    private fun sessionBuilder(base: String, jukeboxId: String): HttpUrl.Builder? =
        root(base)?.addPathSegment("jukebox")?.addPathSegment(jukeboxId)

    private fun session(base: String, jukeboxId: String, leaf: String): HttpUrl? =
        sessionBuilder(base, jukeboxId)?.addPathSegment(leaf)?.build()
}
