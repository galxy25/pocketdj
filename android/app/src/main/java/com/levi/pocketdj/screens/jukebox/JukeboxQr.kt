package com.levi.pocketdj.screens.jukebox

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * The scannable session QR (specs/jukebox.md §6.1): payload is exactly the
 * guest URL, verbatim; error-correction level M; ZXing core only (pure Java,
 * offline). Black modules on a WHITE ROUNDED CARD with generous padding — the
 * white card + quiet zone are load-bearing for phone cameras against the dark
 * app background.
 */
@Composable
fun JukeboxQrCard(url: String, modifier: Modifier = Modifier) {
    val qr = remember(url) { jukeboxQrBitmap(url) }
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White)
            .padding(14.dp),
    ) {
        if (qr != null) {
            Image(
                bitmap = qr,
                contentDescription = "QR code linking to the guest request page",
                modifier = Modifier.size(220.dp),
                filterQuality = FilterQuality.None,
            )
        } else {
            Text(
                text = "QR unavailable",
                style = MaterialTheme.typography.bodyMedium,
                color = Color.Black,
                modifier = Modifier.padding(24.dp),
            )
        }
    }
}

/**
 * Render the matrix at an integer scale (1 module → n×n pixels, no
 * filtering/interpolation) so modules stay sharp squares; ZXing's default
 * 4-module quiet zone rides along.
 */
internal fun jukeboxQrBitmap(text: String, targetPx: Int = 512): ImageBitmap? = runCatching {
    val matrix = QRCodeWriter().encode(
        text,
        BarcodeFormat.QR_CODE,
        1,
        1,
        mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M),
    )
    val scale = (targetPx / matrix.width).coerceAtLeast(1)
    val side = matrix.width * scale
    val pixels = IntArray(side * side)
    for (y in 0 until side) {
        val row = y * side
        val moduleY = y / scale
        for (x in 0 until side) {
            pixels[row + x] = if (matrix.get(x / scale, moduleY)) BLACK else WHITE
        }
    }
    Bitmap.createBitmap(pixels, side, side, Bitmap.Config.ARGB_8888).asImageBitmap()
}.getOrNull()

private const val BLACK = 0xFF000000.toInt()
private const val WHITE = 0xFFFFFFFF.toInt()
