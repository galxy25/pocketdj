package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.PdjJson
import kotlinx.serialization.Serializable

/**
 * The per-beat analysis sidecar (`analysis-<songId>.json`; iOS `RipsStore.BeatGridSidecar`).
 * Every field is optional/defaulted — exactly like iOS, a JSON object decodes; anything that is
 * not a JSON object (truncated body, HTML error page) does NOT, which is the "validate before
 * caching" gate.
 */
@Serializable
data class BeatGridSidecar(
    val beatGridBpm: Double? = null,
    val firstDownbeatMs: Int? = null,
    val steady: Boolean? = null,
    val beatsMs: List<Int> = emptyList(),
    val downbeatsMs: List<Int> = emptyList(),
) {
    companion object {
        /** Null when [text] is not a decodable sidecar. */
        fun parse(text: String): BeatGridSidecar? =
            runCatching { PdjJson.lenient.decodeFromString(serializer(), text) }.getOrNull()
    }
}
