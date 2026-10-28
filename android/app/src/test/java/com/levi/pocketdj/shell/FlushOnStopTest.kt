package com.levi.pocketdj.shell

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FlushOnStopTest {
    private class Owner : LifecycleOwner {
        val reg = LifecycleRegistry.createUnsafe(this)
        override val lifecycle: Lifecycle get() = reg
    }

    @Test
    fun onStopReachesCollectionsStoreFlushNow() {
        val f = File.createTempFile("col", ".json").also { it.delete(); it.deleteOnExit() }
        val pending = ArrayDeque<Runnable>() // queued, never run: simulates a backlog
        val store = CollectionsStore(f, writer = VersionedJsonWriter(f) { pending.addLast(it) })
        val pocket = store.createPocket("P")
        store.addSongs(listOf("a", "b"), AddTarget(AddTarget.Kind.POCKET, pocket.id))
        assertTrue(!f.exists())

        val module = object : FeatureModule {
            override val area = "collections"
            override val flushables = listOf(Flushable { store.flushNow() })
        }
        val owner = Owner()
        owner.reg.addObserver(FlushOnStop(FeatureModuleRegistry(listOf(module))))
        owner.reg.currentState = Lifecycle.State.STARTED
        owner.reg.currentState = Lifecycle.State.CREATED // ON_STOP
        assertTrue(f.exists() && f.readText().contains("\"b\""))
        assertEquals(2, store.pockets.single().songIds.size)
    }
}
