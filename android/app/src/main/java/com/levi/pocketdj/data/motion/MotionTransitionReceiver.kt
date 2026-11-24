package com.levi.pocketdj.data.motion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.SystemClock
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult

/**
 * Receives Activity Recognition transitions (also while the process was dead; builds the graph on demand) and appends
 * them to the device-local timeline. Debug builds also accept the extra `pdj.motionFake=WALKING` (an ENTER now) so the
 * pipeline can be driven from adb without moving.
 */
class MotionTransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val fake = if (debuggable) intent.getStringExtra(EXTRA_FAKE) else null
        val hasResult = runCatching { ActivityTransitionResult.hasResult(intent) }.getOrDefault(false)
        if (fake == null && !hasResult) return
        val pending = goAsync()
        Thread {
            try {
                val graph = com.levi.pocketdj.di.AppGraph.get(context).pocketsGraph
                val store = graph.motionStore
                if (!store.isActive) return@Thread
                val timeline = graph.motionTimeline
                val nowMs = System.currentTimeMillis()
                if (fake != null) {
                    val tok = tokenForName(fake)
                    if (tok != null) timeline.onTransition(tok, entering = true, atMs = nowMs)
                } else {
                    val result = ActivityTransitionResult.extractResult(intent) ?: return@Thread
                    val elapsedNowNs = SystemClock.elapsedRealtimeNanos()
                    for (e in result.transitionEvents.sortedBy { it.elapsedRealTimeNanos }) {
                        val tok = ActivityTransitionSource.tokenFor(e.activityType) ?: continue
                        val at = nowMs - (elapsedNowNs - e.elapsedRealTimeNanos) / 1_000_000
                        timeline.onTransition(tok, e.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER, at)
                    }
                }
            } catch (_: Exception) {
            } finally {
                pending.finish()
            }
        }.start()
    }

    companion object {
        const val EXTRA_FAKE = "pdj.motionFake"

        /** "WALKING" / "walking" / "IN_VEHICLE" / "ON_BICYCLE" -> token. */
        fun tokenForName(name: String): String? = when (name.trim().uppercase()) {
            "RUNNING" -> "running"
            "WALKING" -> "walking"
            "ON_BICYCLE", "CYCLING" -> "cycling"
            "IN_VEHICLE", "AUTOMOTIVE" -> "automotive"
            "STILL", "STATIONARY" -> "stationary"
            else -> null
        }
    }
}
