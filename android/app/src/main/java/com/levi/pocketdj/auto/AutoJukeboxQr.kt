package com.levi.pocketdj.auto

import android.content.Context
import android.graphics.Bitmap
import androidx.core.content.FileProvider
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import java.io.File
import java.security.MessageDigest

/**
 * The jukebox join QR for the car (iOS `CarPlayModel.jukeboxQR`): a zxing bitmap written to the app cache and served
 * to the head unit as `content://` artwork through the FileProvider. The payload is the guest URL only; the host
 * key never rides in it ([payload] strips one defensively).
 */
object AutoJukeboxQr {
    /** Hosts that render media artwork for Android Auto; the URI is granted to each (best effort, DHU-verified). */
    val ART_READERS = listOf("com.google.android.projection.gearhead", "com.google.android.gms", "com.google.android.googlequicksearchbox")

    private val HOST_KEY_PARAMS = setOf("hostkey", "host_key", "hostsecret")

    /** The exact text encoded: the guest URL with any host-key query parameter removed. */
    fun payload(url: String): String {
        val q = url.indexOf('?')
        if (q < 0) return url
        val frag = url.indexOf('#', q).let { if (it < 0) url.length else it }
        val kept = url.substring(q + 1, frag).split('&').filter { p ->
            p.isNotEmpty() && p.substringBefore('=').lowercase() !in HOST_KEY_PARAMS
        }
        return url.substring(0, q) + (if (kept.isEmpty()) "" else "?" + kept.joinToString("&")) + url.substring(frag)
    }

    /** True for an artwork URI the car art loader may be handed: our own FileProvider content URI. */
    fun isContentArt(uri: String?): Boolean = uri?.startsWith("content://", ignoreCase = true) == true

    /** Stable cache file name for a session url (a hash, never the url itself). */
    fun fileName(url: String): String {
        val h = MessageDigest.getInstance("SHA-256").digest(payload(url).toByteArray()).take(8)
        return "jukebox-qr-" + h.joinToString("") { "%02x".format(it) } + ".png"
    }

    /** The QR module matrix as black/white ARGB pixels at an integer scale (pure JVM; null when the text cannot be encoded). */
    fun pixels(text: String, targetPx: Int = 512): Pair<IntArray, Int>? = runCatching {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 1, 1, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M))
        val scale = (targetPx / m.width).coerceAtLeast(1)
        val side = m.width * scale
        val px = IntArray(side * side)
        for (y in 0 until side) for (x in 0 until side) px[y * side + x] = if (m.get(x / scale, y / scale)) BLACK else WHITE
        px to side
    }.getOrNull()

    /** Writes the QR PNG (idempotent) and returns its `content://` URI string, or null on any failure. */
    fun artworkUri(context: Context, url: String): String? = runCatching {
        val (px, side) = pixels(payload(url)) ?: return null
        val dir = File(context.cacheDir, "auto-qr").apply { mkdirs() }
        val f = File(dir, fileName(url))
        if (!f.exists() || f.length() == 0L) {
            val bmp = Bitmap.createBitmap(px, side, side, Bitmap.Config.ARGB_8888)
            f.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", f)
        for (pkg in ART_READERS) runCatching { context.grantUriPermission(pkg, uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        uri.toString()
    }.getOrNull()

    private const val BLACK = 0xFF000000.toInt()
    private const val WHITE = 0xFFFFFFFF.toInt()
}
