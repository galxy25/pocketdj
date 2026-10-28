package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioDiag

/** Runs [block] with AudioDiag lines captured (and restored) so engine tests can assert the emitted reason lines. */
internal inline fun captureAudioDiag(block: (lines: List<String>) -> Unit) {
    val lines = java.util.Collections.synchronizedList(ArrayList<String>())
    val saved = AudioDiag.emit
    AudioDiag.emit = { lines.add(it) }
    try { block(lines) } finally { AudioDiag.emit = saved }
}
