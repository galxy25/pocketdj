package com.levi.pocketdj.auto

import java.util.Collections

/**
 * Whether an Android Auto / automotive media controller is connected to [com.levi.pocketdj.playback.PlaybackService]
 * right now. Voice ("Hey Google, play my pocket") and `pocketdj://pocket/now` while the phone projects to a car then plan
 * in carPlay mode, like a tap on the Auto tree (UI_MODE_TYPE_CAR alone does not detect phone projection).
 */
object AutoSessionTracker {
    private val active: MutableSet<Any> = Collections.synchronizedSet(HashSet())

    val isActive: Boolean get() = active.isNotEmpty()

    fun connected(controller: Any) { active.add(controller) }
    fun disconnected(controller: Any) { active.remove(controller) }
    fun reset() = active.clear()
}
