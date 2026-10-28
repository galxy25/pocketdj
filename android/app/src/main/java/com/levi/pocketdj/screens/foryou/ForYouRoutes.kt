package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.ForYouTileRoute
import com.levi.pocketdj.data.settings.PrefKey
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Tile route encoding (`foryou/{tileId}`; tile ids are `new`, `zone`, `col-<collectionId>`).
 * History hosts the For You detail screens itself, but the string form is what a restored
 * back-stack / deep link / BRW-14's New screen route uses, so it is a pure, tested codec.
 */
object ForYouRoutes {
    const val PREFIX = "foryou"
    const val NEW_ROUTE = "$PREFIX/new"

    fun encode(route: ForYouTileRoute): String =
        "$PREFIX/" + when (route.kind) {
            ForYouTileKind.NEW -> "new"
            ForYouTileKind.ZONE -> "zone"
            ForYouTileKind.COLLECTION -> "col-" + URLEncoder.encode(route.collectionId.orEmpty(), "UTF-8")
        }

    /** Null for anything that is not a well-formed For You route. [titleFor] names a collection id. */
    fun decode(route: String, titleFor: (String) -> String? = { null }): ForYouTileRoute? {
        if (!route.startsWith("$PREFIX/")) return null
        val tail = route.removePrefix("$PREFIX/")
        return when {
            tail == "new" -> ForYouTileRoute(ForYouTileKind.NEW, title = "New")
            tail == "zone" -> ForYouTileRoute(ForYouTileKind.ZONE, title = "In Da Zone")
            tail.startsWith("col-") && tail.length > 4 -> {
                val id = runCatching { URLDecoder.decode(tail.removePrefix("col-"), "UTF-8") }.getOrNull()
                    ?.takeIf { it.isNotEmpty() } ?: return null
                ForYouTileRoute(ForYouTileKind.COLLECTION, id, titleFor(id) ?: "Suggestions")
            }
            else -> null
        }
    }
}

/**
 * Is History ▸ For You visible? iOS: `recEngineEnabled || recFixtureOn`. The engine toggle is
 * persisted under iOS's key name (Settings ▸ Recommendations, a later package, writes it); the
 * fixture is any debug build so the tab is reachable on the emulator with seeded history.
 */
object ForYouGate {
    val REC_ENGINE_ENABLED = PrefKey.boolean("recEngineEnabled", false)

    fun visible(recEngineEnabled: Boolean, debugFixture: Boolean): Boolean = recEngineEnabled || debugFixture
}
