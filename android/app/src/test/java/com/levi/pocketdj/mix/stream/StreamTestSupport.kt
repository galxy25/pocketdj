package com.levi.pocketdj.mix.stream

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer

/** Range-aware origin: serves [bodies] by path; per-path knobs for failure / throttling. */
class Origin : Dispatcher() {
    val bodies = ConcurrentHashMap<String, ByteArray>()
    /** Forced status for a path (e.g. 404, 403, 500). */
    val status = ConcurrentHashMap<String, Int>()
    /** Every request drops the connection part-way through the body. */
    val alwaysDrop = ConcurrentHashMap.newKeySet<String>()
    /** Only the first request drops; the Range retry succeeds. */
    val dropFirst = ConcurrentHashMap.newKeySet<String>()
    /** Trickle the body: bytes per 150 ms. */
    val throttle = ConcurrentHashMap<String, Long>()
    /** Ignore Range and answer 200 with the whole object. */
    val ignoreRange = ConcurrentHashMap.newKeySet<String>()
    val hits = ConcurrentHashMap<String, CopyOnWriteArrayList<String>>()

    fun ranges(path: String): List<String> = hits[path]?.toList() ?: emptyList()

    override fun dispatch(request: RecordedRequest): MockResponse {
        val path = request.path ?: "/"
        val range = request.getHeader("Range")
        hits.getOrPut(path) { CopyOnWriteArrayList() }.add(range ?: "-")
        status[path]?.let { return MockResponse().setResponseCode(it).setBody("nope") }
        val body = bodies[path] ?: return MockResponse().setResponseCode(404)
        val first = hits[path]!!.size == 1
        val res = MockResponse()
        val start = if (range != null && path !in ignoreRange) range.removePrefix("bytes=").removeSuffix("-").toInt() else 0
        if (start > 0) {
            res.setResponseCode(206).setHeader("Content-Range", "bytes $start-${body.size - 1}/${body.size}")
        }
        res.setBody(Buffer().write(body, start, body.size - start))
        throttle[path]?.let { res.throttleBody(it, 150, TimeUnit.MILLISECONDS) }
        if (path in alwaysDrop || (path in dropFirst && first)) res.socketPolicy = SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY
        return res
    }
}

fun waitUntil(timeoutMs: Long = 10_000, what: String = "condition", cond: () -> Boolean) {
    val end = System.nanoTime() + timeoutMs * 1_000_000
    while (System.nanoTime() < end) {
        if (cond()) return
        Thread.sleep(10)
    }
    throw AssertionError("timed out waiting for $what")
}

fun bytesOf(n: Int, seed: Int = 1) = ByteArray(n) { ((it * 31 + seed) and 0xFF).toByte() }
