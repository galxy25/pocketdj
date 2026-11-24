package com.levi.pocketdj.screens.settings

import android.Manifest
import android.content.pm.PackageManager
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.levi.pocketdj.data.sync.LinkCode
import java.util.concurrent.Executors

/** Pure: turns a scanned QR payload (or pasted text / deep link) into a bare, VALID link code, else null. */
object LinkScan {
    /**
     * Accepts `pocketdj://link?code=<code>`, `pocketdj://link/<code>`, or a bare (grouped or not) code.
     * A mistyped/foreign payload fails [LinkCode]'s checksum here, locally, before any network.
     */
    fun extract(raw: String?): String? {
        val t = raw?.trim().orEmpty()
        if (t.isEmpty()) return null
        val candidate = if (t.contains("://")) {
            val lower = t.lowercase()
            if (!lower.startsWith("pocketdj://link")) return null
            val q = Regex("[?&]code=([^&#]+)", RegexOption.IGNORE_CASE).find(t)?.groupValues?.get(1)
            q ?: t.substring("pocketdj://link".length).substringBefore('?').substringBefore('#').trim('/')
        } else t
        if (candidate.isBlank()) return null
        return if (LinkCode.decode(candidate) is LinkCode.Decoded.Ok) candidate else null
    }
}

/** Camera permission on demand, then a live preview that reports the first valid link code via [onCode]. */
@Composable
internal fun QrScanner(onCode: (String) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var denied by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok; denied = !ok
    }
    Column(Modifier.fillMaxWidth().testTag("link-scanner")) {
        if (!granted) {
            SettingsCaption(
                if (denied) "Camera access was declined. You can type the code instead, or allow the camera in system settings."
                else "PocketDJ uses the camera only to scan the QR code from your other device. Nothing is recorded or stored.",
            )
            Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }, modifier = Modifier.testTag("link-scan-allow")) { Text("Allow camera") }
        } else {
            ScannerPreview(onCode)
        }
        OutlinedButton(onClick = onCancel, modifier = Modifier.testTag("link-scan-cancel")) { Text("Cancel") }
    }
}

@Composable
private fun ScannerPreview(onCode: (String) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    val view = remember { PreviewView(context) }
    var delivered by remember { mutableStateOf(false) }
    DisposableEffect(owner) {
        val future = ProcessCameraProvider.getInstance(context)
        var provider: ProcessCameraProvider? = null
        var disposed = false
        var analysisRef: ImageAnalysis? = null
        future.addListener({
            if (disposed) return@addListener
            val p = runCatching { future.get() }.getOrNull() ?: return@addListener
            provider = p
            val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysisRef = analysis
            analysis.setAnalyzer(executor) { image ->
                val code = decodeLinkCode(image)
                if (code != null && !delivered) {
                    delivered = true
                    view.post { onCode(code) }
                }
            }
            runCatching {
                p.unbindAll()
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            disposed = true
            analysisRef?.clearAnalyzer()
            provider?.unbindAll()
            executor.shutdown()
        }
    }
    AndroidView(factory = { view }, modifier = Modifier.fillMaxWidth().height(260.dp).testTag("link-scan-preview"))
}

private val reader = MultiFormatReader().apply {
    setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
}

/** Decodes the Y (luminance) plane of a camera frame with zxing; null unless it holds a valid link code. */
private fun decodeLinkCode(image: ImageProxy): String? = image.use {
    val plane = it.planes[0]
    val buf = plane.buffer
    val raw = ByteArray(buf.remaining()).also { b -> buf.get(b) }
    val rowStride = plane.rowStride
    val rows = maxOf(it.height, raw.size / rowStride)
    val data = if (raw.size >= rowStride * rows) raw else raw.copyOf(rowStride * rows)
    synchronized(reader) { runCatching {
        val src = PlanarYUVLuminanceSource(data, rowStride, rows, 0, 0, minOf(it.width, rowStride), minOf(it.height, rows), false)
        LinkScan.extract(reader.decodeWithState(BinaryBitmap(HybridBinarizer(src))).text)
    }.also { reader.reset() }.getOrNull() }
}
