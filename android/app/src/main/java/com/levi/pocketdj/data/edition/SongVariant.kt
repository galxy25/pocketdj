package com.levi.pocketdj.data.edition

/**
 * Song EDITION selector. Variant ids ride every songId-keyed system as
 * "<baseId>_clean" / "<baseId>_explicit" (base = `sng_<12 lowercase hex>`).
 */
enum class SongVariant(val raw: String) {
    CLEAN("clean"), EXPLICIT("explicit");

    data class Parsed(val base: String, val variant: SongVariant)

    private val suffix: String = "_$raw"

    companion object {
        fun parse(songId: String): Parsed? {
            // Hot path (every catalog row in recs ranking / burn lookups): no per-call suffix allocation.
            for (v in entries) {
                val suffix = v.suffix
                if (!songId.endsWith(suffix)) continue
                val base = songId.dropLast(suffix.length)
                if (!base.startsWith("sng_")) return null
                val hex = base.drop(4)
                if (hex.length != 12 || !hex.all { it in '0'..'9' || it in 'a'..'f' }) return null
                return Parsed(base, v)
            }
            return null
        }

        fun baseId(id: String): String = parse(id)?.base ?: id

        fun variantId(base: String, v: SongVariant): String = "${base}_${v.raw}"
    }
}
