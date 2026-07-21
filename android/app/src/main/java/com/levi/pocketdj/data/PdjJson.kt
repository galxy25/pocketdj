package com.levi.pocketdj.data

import kotlinx.serialization.json.Json

/**
 * The one lenient Json used for every PocketDJ document (remote and on-disk).
 *
 * Iron law (ported from iOS): decode leniently — unknown keys ignored, explicit
 * JSON `null` and absent keys both land on the Kotlin default — so a later field
 * addition never wipes a saved doc or breaks a catalog/manifest decode
 * (specs/catalog.md §4 nullability rule, §9; specs/playback.md §2.2).
 */
object PdjJson {
    val lenient: Json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
        explicitNulls = false
    }
}
