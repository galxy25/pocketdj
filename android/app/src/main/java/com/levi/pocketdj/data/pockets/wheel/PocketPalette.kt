package com.levi.pocketdj.data.pockets.wheel

import java.security.MessageDigest
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/** What a wheel cell is painted with (iOS `PocketSwatch`). */
sealed class PocketSwatch {
    data class Slot(val index: Int) : PocketSwatch()
    /** A 13th+ dominant collection: hashed hue at low chroma (drawn hatched). */
    data class Overflow(val hue: Double) : PocketSwatch()
    /** No collection >= 25 % - neutral grey with a fine stripe. */
    data object Mixed : PocketSwatch()

    val isHatched: Boolean get() = this is Overflow

    /** sRGB components (0..1) for this swatch in the given scheme. */
    fun rgb(dark: Boolean): Triple<Double, Double, Double> = when (this) {
        is Slot -> {
            val t = if (dark) DARK_RGB else LIGHT_RGB
            t[((index % t.size) + t.size) % t.size]
        }
        is Overflow -> oklchToSRGB(if (dark) 0.72 else 0.58, 0.08, hue)
        Mixed -> if (dark) Triple(0.55, 0.57, 0.62) else Triple(0.62, 0.63, 0.66)
    }

    /** Opaque ARGB int for [rgb]. */
    fun argb(dark: Boolean): Int {
        val (r, g, b) = rgb(dark)
        fun c(x: Double) = (x * 255).roundToInt().coerceIn(0, 255)
        return (0xFF shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    companion object {
        /**
         * The palette (OKLCH L 0.72 / C 0.15 dark, L 0.58 light; sRGB, gamut-clipped). Hue order
         * 25,145,265,85,205,325,55,175,295,115,235,355. Copied exactly from iOS.
         */
        val DARK_RGB: List<Triple<Double, Double, Double>> = listOf(
            Triple(0.9574, 0.4822, 0.4539), Triple(0.3811, 0.7399, 0.4024), Triple(0.4629, 0.6302, 1.0),
            Triple(0.8128, 0.6094, 0.0), Triple(0.0, 0.7447, 0.8191), Triple(0.8276, 0.5068, 0.8465),
            Triple(0.9206, 0.5328, 0.2301), Triple(0.0, 0.761, 0.6243), Triple(0.6748, 0.5624, 0.9718),
            Triple(0.6363, 0.6854, 0.1612), Triple(0.0691, 0.6965, 0.9577), Triple(0.9242, 0.4752, 0.6639),
        )
        val LIGHT_RGB: List<Triple<Double, Double, Double>> = listOf(
            Triple(0.7659, 0.3107, 0.2939), Triple(0.1985, 0.5662, 0.2358), Triple(0.3051, 0.4584, 0.8247),
            Triple(0.6368, 0.4402, 0.0), Triple(0.0, 0.5694, 0.6434), Triple(0.6483, 0.3394, 0.6684),
            Triple(0.7338, 0.3628, 0.0), Triple(0.0, 0.5857, 0.4595), Triple(0.5102, 0.3935, 0.7862),
            Triple(0.4732, 0.5143, 0.0), Triple(0.0, 0.5225, 0.7735), Triple(0.7353, 0.3057, 0.497),
        )

        /** OKLCH -> gamma-encoded sRGB (clipped) - Bjorn Ottosson's matrices. */
        fun oklchToSRGB(L: Double, C: Double, h: Double): Triple<Double, Double, Double> {
            val rad = h * Math.PI / 180
            val a = C * cos(rad)
            val b = C * sin(rad)
            val l_ = L + 0.3963377774 * a + 0.2158037573 * b
            val m_ = L - 0.1055613458 * a - 0.0638541728 * b
            val s_ = L - 0.0894841775 * a - 1.2914855480 * b
            val l = l_ * l_ * l_
            val m = m_ * m_ * m_
            val s = s_ * s_ * s_
            val r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
            val g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
            val bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
            fun enc(x: Double): Double {
                val c = min(1.0, max(0.0, x))
                return if (c <= 0.0031308) 12.92 * c else 1.055 * c.pow(1 / 2.4) - 0.055
            }
            return Triple(enc(r), enc(g), enc(bl))
        }

        /** Overflow hue (degrees) from sha256(id) - stable on every device. */
        fun overflowHue(id: String): Double {
            val d = MessageDigest.getInstance("SHA-256").digest(id.toByteArray(Charsets.UTF_8))
            val v = ((d[0].toInt() and 0xFF) shl 8) or (d[1].toInt() and 0xFF)
            return v.toDouble() / 65_536 * 360
        }
    }
}
