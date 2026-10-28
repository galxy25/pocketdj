package com.levi.pocketdj.mix.store

import java.io.File
import java.util.concurrent.Executor

/** Deterministic scheduler: tasks run only when the test advances the clock past their due time. */
class ManualScheduler(private val clock: TestClock) : StoreScheduler {
    private class Item(val due: Long, val task: Runnable, var cancelled: Boolean = false)
    private val items = ArrayList<Item>()

    val pending: Int get() = items.count { !it.cancelled }

    override fun schedule(delayMs: Long, task: Runnable): Cancellable {
        val it = Item(clock.now + delayMs, task)
        items.add(it)
        return Cancellable { it.cancelled = true }
    }

    fun advance(ms: Long) {
        clock.now += ms
        while (true) {
            val next = items.filter { !it.cancelled && it.due <= clock.now }.minByOrNull { it.due } ?: break
            items.remove(next)
            next.task.run()
        }
    }
}

class TestClock(var now: Long = 1_800_000_000_000L) {
    fun read(): Long = now
}

/** Executor that queues work until [drain], to exercise version ordering against stragglers. */
class QueueExecutor : Executor {
    private val q = ArrayDeque<Runnable>()
    override fun execute(command: Runnable) { q.addLast(command) }
    fun drain() { while (q.isNotEmpty()) q.removeFirst().run() }
}

fun fixtureText(name: String): String =
    (object {}.javaClass.classLoader!!.getResourceAsStream("mix/$name") ?: error("missing fixture $name"))
        .bufferedReader().use { it.readText() }

fun tempFile(name: String): File =
    File.createTempFile("pdj-mix-", "-$name").also { it.delete(); it.deleteOnExit() }
