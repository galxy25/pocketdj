package com.levi.pocketdj.work

import com.levi.pocketdj.shell.PeriodicWorkSpec
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkSchedulerPolicyTest {
    @Test fun shellSpecsProduceExpectedPlans() {
        val plans = WorkSchedulerPolicy.plan(ShellWork.specs)
        assertEquals(listOf("pdj.rip-reconcile", "pdj.storage-prune"), plans.map { it.uniqueName })
        assertEquals(15L, plans[0].intervalMinutes)
        assertTrue(plans[0].requiresConnected)
        assertEquals(1440L, plans[1].intervalMinutes)
        assertTrue(!plans[1].requiresConnected)
        assertTrue(plans.all { it.policy == androidx.work.ExistingPeriodicWorkPolicy.KEEP })
    }

    @Test fun duplicatesCollapseAndFloorApplies() {
        val plans = WorkSchedulerPolicy.plan(
            listOf(PeriodicWorkSpec("x", 5), PeriodicWorkSpec("x", 60)),
        )
        assertEquals(1, plans.size)
        assertEquals(15L, plans[0].intervalMinutes)
    }

    @Test fun noSpecsNoPlans() {
        assertTrue(WorkSchedulerPolicy.plan(emptyList()).isEmpty())
    }

    @Test fun bodySuccessAndIoRetry() = runBlocking {
        assertEquals(WorkOutcome.SUCCESS, runWorkBody { })
        assertEquals(WorkOutcome.RETRY, runWorkBody { throw IOException("net") })
    }
}
