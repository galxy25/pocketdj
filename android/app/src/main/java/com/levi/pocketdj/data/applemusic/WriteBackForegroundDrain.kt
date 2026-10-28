package com.levi.pocketdj.data.applemusic

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver

/**
 * COL-8 (iOS `scenePhase == .active -> playlistWriteBack.runSoon()`): the queue has no internal
 * timer, and an Android process can live for days, so backed-off or signed-out jobs must be
 * re-armed on every process foreground.
 */
class WriteBackForegroundDrain(private val drain: () -> Unit) : LifecycleEventObserver {
    override fun onStateChanged(source: androidx.lifecycle.LifecycleOwner, event: Lifecycle.Event) {
        if (event == Lifecycle.Event.ON_START) runCatching { drain() }
    }
}
