package com.levi.pocketdj.shell

import androidx.lifecycle.LifecycleOwner
import java.lang.reflect.Proxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class AppLifecycleObserverTest {
    private val owner = Proxy.newProxyInstance(
        LifecycleOwner::class.java.classLoader, arrayOf(LifecycleOwner::class.java),
    ) { _, _, _ -> null } as LifecycleOwner

    @Test fun throwingForegroundHookDoesNotStopTheRest() {
        var ran = 0
        val job = Job()
        val o = AppLifecycleObserver(
            CoroutineScope(Dispatchers.Unconfined + job),
            listOf({ throw IllegalStateException("x") }, { ran++ }, { ran++ }),
        ) { }
        o.onStart(owner)
        assertEquals(2, ran)
    }

    @Test fun stopRunsFlushAndSwallowsFailure() = runBlocking {
        var flushed = 0
        val o = AppLifecycleObserver(CoroutineScope(Dispatchers.Unconfined + Job()), emptyList()) {
            flushed++
            throw IllegalStateException("boom")
        }
        o.onStop(owner)
        assertEquals(1, flushed)
    }
}
