package com.levi.pocketdj.mix.stream

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Port of iOS `StreamSink`: writes each transfer's bytes straight to its file and reports
 * throttled progress as [Event]s. Every transfer emits strictly `Response -> Bytes* -> Finished`
 * from ONE coroutine, so a consumer that preserves arrival order sees them in that order.
 *
 *  - A non-2xx response emits [Event.Response] and then nothing (the consumer cancels/fails it).
 *  - 200 (full body, e.g. a server that ignored Range) restarts the file at byte 0; 206 appends.
 *  - Progress is coalesced to ~4 Hz or every 256 KB, whichever first; the unreported tail is
 *    flushed just before [Event.Finished].
 *  - [cancel] silences the transfer: no further events at all (iOS "cancelled through cancel(task:)").
 */
class StreamSink(
    private val client: OkHttpClient,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val onEvent: (Event) -> Unit,
) {
    sealed interface Event {
        val task: Int

        /** [expected] is the response Content-Length (-1 when unknown); [contentRangeTotal] the `/total` of Content-Range. */
        data class Response(
            override val task: Int,
            val status: Int,
            val expected: Long,
            val contentRangeTotal: Long?,
        ) : Event

        data class Bytes(override val task: Int, val total: Long, val delta: Long) : Event
        data class Finished(override val task: Int, val total: Long, val error: Throwable?) : Event
    }

    private class Transfer(val job: Job) {
        @Volatile var call: okhttp3.Call? = null
    }

    private val transfers = ConcurrentHashMap<Int, Transfer>()

    /** Begin (or resume at [offset]) a GET of [url] into [file]. [file] must already exist for offset > 0. */
    fun start(task: Int, url: String, file: File, offset: Long) {
        lateinit var transfer: Transfer
        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) { run(task, url, file, offset, transfer) }
        transfer = Transfer(job)
        transfers[task] = transfer
        job.start()
    }

    fun cancel(task: Int) {
        val t = transfers.remove(task) ?: return
        t.call?.cancel()
        t.job.cancel()
    }

    fun isActive(task: Int): Boolean = transfers.containsKey(task)

    private fun emit(task: Int, event: Event) {
        // A cancelled transfer is silent, even for an event already in flight.
        if (transfers.containsKey(task)) onEvent(event)
    }

    private suspend fun run(task: Int, url: String, file: File, offset: Long, transfer: Transfer) {
        var total = offset
        var unreported = 0L
        var lastReport = Long.MIN_VALUE / 2
        var raf: RandomAccessFile? = null
        try {
            val req = Request.Builder().url(url).apply {
                if (offset > 0) header("Range", "bytes=$offset-")
            }.build()
            val call = client.newCall(req)
            transfer.call = call
            call.execute().use { resp ->
                val status = resp.code
                val rangeTotal = resp.header("Content-Range")?.substringAfterLast('/', "")?.toLongOrNull()
                val expected = resp.body?.contentLength() ?: -1L
                val ok = status in 200..299
                if (ok) {
                    if (status == 200) total = 0
                    raf = RandomAccessFile(file, "rw").also {
                        if (status == 200) it.setLength(0)
                        it.seek(if (status == 200) 0 else it.length())
                    }
                }
                emit(task, Event.Response(task, status, expected, rangeTotal))
                if (!ok) {
                    transfers.remove(task)
                    return
                }
                val body = resp.body ?: throw IOException("empty body")
                val buf = ByteArray(32 * 1024)
                body.byteStream().use { input ->
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val n = input.read(buf)
                        if (n < 0) break
                        raf!!.write(buf, 0, n)
                        total += n
                        unreported += n
                        val now = clock()
                        if (now - lastReport >= REPORT_INTERVAL_MS || unreported >= REPORT_BYTES) {
                            val delta = unreported
                            unreported = 0
                            lastReport = now
                            emit(task, Event.Bytes(task, total, delta))
                        }
                    }
                }
            }
            runCatching { raf?.fd?.sync() }
            raf?.close(); raf = null
            if (unreported > 0) emit(task, Event.Bytes(task, total, unreported))
            finish(task, total, null)
        } catch (e: CancellationException) {
            runCatching { raf?.close() }
            // cancel(task) already removed the transfer: nothing to report.
        } catch (e: Throwable) {
            runCatching { raf?.close() }
            if (unreported > 0) emit(task, Event.Bytes(task, total, unreported))
            finish(task, total, e)
        }
    }

    private fun finish(task: Int, total: Long, error: Throwable?) {
        emit(task, Event.Finished(task, total, error))
        transfers.remove(task)
    }

    companion object {
        const val REPORT_INTERVAL_MS = 250L
        const val REPORT_BYTES = 262_144L
    }
}
