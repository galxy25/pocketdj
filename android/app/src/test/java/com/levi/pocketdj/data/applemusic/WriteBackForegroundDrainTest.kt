package com.levi.pocketdj.data.applemusic

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import org.junit.Assert.assertEquals
import org.junit.Test

class WriteBackForegroundDrainTest {
    @Test fun drainsOnEveryForeground_notOnOtherEvents() {
        var drains = 0
        val owner = object : LifecycleOwner {
            lateinit var reg: LifecycleRegistry
            override val lifecycle: Lifecycle get() = reg
        }
        owner.reg = LifecycleRegistry.createUnsafe(owner)
        owner.reg.addObserver(WriteBackForegroundDrain { drains++ })
        owner.reg.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        assertEquals(0, drains)
        owner.reg.handleLifecycleEvent(Lifecycle.Event.ON_START)
        assertEquals(1, drains)
        owner.reg.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        owner.reg.handleLifecycleEvent(Lifecycle.Event.ON_START)
        assertEquals(2, drains)
    }
}
