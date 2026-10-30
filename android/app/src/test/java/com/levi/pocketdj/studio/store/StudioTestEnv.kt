package com.levi.pocketdj.studio.store

import java.io.File
import java.util.concurrent.Executor

/** Executor that queues work so tests can run it late / out of order. */
class QueueExecutor : Executor {
    val queue = ArrayDeque<Runnable>()
    override fun execute(command: Runnable) { queue.addLast(command) }
    fun runAll() { while (queue.isNotEmpty()) queue.removeFirst().run() }
    fun runReversed() { val l = queue.toList().reversed(); queue.clear(); l.forEach { it.run() } }
}

/** Debounce seam driven by hand. */
class ManualScheduler : StudioScheduler {
    var pending: (() -> Unit)? = null
    var scheduledCount = 0
    override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
        scheduledCount++
        pending = task
        val mine = task
        return { if (pending === mine) pending = null }
    }
    fun fire() { val t = pending; pending = null; t?.invoke() }
}

/**
 * Roots for tests: app roots under [base]/app, per-family user roots under [base]/user/<family>
 * that can be flipped unreachable (unplugged drive / revoked SAF permission) per family.
 */
class TestEnv(val base: File) {
    val unreachable = mutableSetOf<StudioFamily>()
    val configured = mutableSetOf<StudioFamily>()   // families with a user folder picked
    val roots: StudioRoots = DefaultStudioRoots(File(base, "app"), userConfigured = { it in configured }) { f ->
        if (f in configured && f !in unreachable) FileStudioDir(File(base, "user/${f.rawValue}").also { it.mkdirs() }) else null
    }
    val docFile = File(base, "pocketdj-studio.json")

    fun appFile(f: StudioFamily, name: String) = File(File(base, "app/${f.rawValue}").also { it.mkdirs() }, name)
    fun userFile(f: StudioFamily, name: String) = File(File(base, "user/${f.rawValue}").also { it.mkdirs() }, name)

    /** Write the family's deterministic file for [id] (app or user root); returns the file name. */
    fun write(f: StudioFamily, id: String, user: Boolean = false, bytes: Int = 10): String {
        val n = StudioFolders.fileName(f, id)
        (if (user) userFile(f, n) else appFile(f, n)).writeBytes(ByteArray(bytes) { 1 })
        return n
    }

    fun store(
        executor: Executor = com.levi.pocketdj.data.store.VersionedJsonWriter.DIRECT,
        scheduler: StudioScheduler = StudioScheduler { _, _ -> {} },
        now: () -> Double = { 1_000.0 },
    ) = StudioStore(docFile, roots, executor, scheduler, now)
}
