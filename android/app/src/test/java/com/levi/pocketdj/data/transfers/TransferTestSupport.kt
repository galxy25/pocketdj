package com.levi.pocketdj.data.transfers

import java.io.File
import java.nio.file.Files

fun tmpTransferDir(): File = Files.createTempDirectory("pdj-xfer").toFile()

/** Records call order; optionally inspects the persisted file at enqueue time. */
class FakeTransferWork(private val onEnqueue: (BurnWorkSpec) -> Unit = {}) : TransferWork {
    val enqueued = ArrayList<BurnWorkSpec>()
    val cancelled = ArrayList<String>()
    var cancelAllCalls = 0
    var states: Map<String, WorkStateKind> = emptyMap()
    override fun enqueue(spec: BurnWorkSpec) { onEnqueue(spec); enqueued += spec }
    override fun cancel(uniqueNames: Collection<String>) { cancelled += uniqueNames }
    override fun cancelAll() { cancelAllCalls += 1 }
    override suspend fun states(uniqueNames: Collection<String>) = states.filterKeys { it in uniqueNames }
}

fun rec(songId: String, audio: String = "$songId.mp3", sidecar: String = "$songId.txt", source: String = "digital") =
    TransferRecord(
        songId = songId, audioFileName = audio, sidecarFileName = sidecar, sidecarText = "BPM: 120\n",
        manifestKey = "rips/$songId.mp3", source = source, title = "T$songId", artist = "A", createdAt = 1.0,
    )
