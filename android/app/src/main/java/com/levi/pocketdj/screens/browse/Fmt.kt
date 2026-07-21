package com.levi.pocketdj.screens.browse

import androidx.compose.ui.graphics.Color
import com.levi.pocketdj.ui.theme.PdjOnSurfaceVariant
import java.text.Normalizer
import java.util.Locale
import kotlin.math.roundToInt

/** Display formatting, ported from `apple/PocketDJ/Support/Format.swift`. */
object Fmt {
    /** Milliseconds → "m:ss"; absent/zero shows "–" (specs/browse.md §2.1). */
    fun duration(ms: Long?): String {
        if (ms == null || ms <= 0) return "–"
        val totalSeconds = ms / 1000
        return "%d:%02d".format(totalSeconds / 60, totalSeconds % 60)
    }

    /** BPM displays as a rounded Int; absent/zero shows "–". */
    fun bpm(value: Double?): String {
        if (value == null || value <= 0.0) return "–"
        return value.roundToInt().toString()
    }

    private val combiningMarks = Regex("""\p{Mn}+""")

    /**
     * Search fold (specs/browse.md §4.1): NFD-normalize, strip combining marks,
     * lowercase locale-independently. Applied to both search keys and queries.
     */
    fun fold(value: String): String =
        combiningMarks
            .replace(Normalizer.normalize(value, Normalizer.Form.NFD), "")
            .lowercase(Locale.ROOT)
}

/**
 * Camelot-wheel model for harmonic mixing — mirrors
 * `apple/PocketDJ/Support/Format.swift` / `src/lib/camelot.ts`.
 * Code is "<num><A|B>": num 1–12 = wheel position, A = minor, B = major.
 */
object Camelot {
    /** Parse "<num><A|B>" → (num, isMajor), or null. */
    fun parse(code: String?): Pair<Int, Boolean>? {
        if (code == null) return null
        val trimmed = code.trim().uppercase(Locale.ROOT)
        if (trimmed.isEmpty()) return null
        val letter = trimmed.last()
        if (letter != 'A' && letter != 'B') return null
        val num = trimmed.dropLast(1).toIntOrNull() ?: return null
        if (num !in 1..12) return null
        return num to (letter == 'B')
    }

    /** Comparable rank (A=even, B=odd, contiguous) → numeric compare = wheel order. */
    fun rank(code: String?): Int? {
        val (num, major) = parse(code) ?: return null
        return num * 2 + if (major) 1 else 0
    }

    /**
     * Chip color: HSL(hue=(num-1)/12, s 0.68, l 0.50 major / 0.38 minor)
     * (specs/browse.md §5); unparseable codes render in the dim foreground.
     */
    fun color(code: String?): Color {
        val (num, major) = parse(code) ?: return PdjOnSurfaceVariant
        val hue = (num - 1) / 12f * 360f
        return Color.hsl(hue, 0.68f, if (major) 0.50f else 0.38f)
    }
}
