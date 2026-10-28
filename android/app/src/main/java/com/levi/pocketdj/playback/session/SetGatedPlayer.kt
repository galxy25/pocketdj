package com.levi.pocketdj.playback.session

import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import java.util.concurrent.CopyOnWriteArrayList

/** Pure command masking so it is testable without a player. */
object SetGate {
    val GATED = intArrayOf(
        Player.COMMAND_SEEK_TO_NEXT,
        Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_PREVIOUS,
        Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
        Player.COMMAND_SET_REPEAT_MODE,
        Player.COMMAND_SET_SHUFFLE_MODE,
    )

    /**
     * While a set runs, next/prev/repeat/shuffle are forced on (the sequencer serves them). When it
     * does not, ExoPlayer's own answer stands for a real multi-item queue (an album has a next);
     * only an empty/single-item timeline - which cannot skip - is masked.
     */
    fun apply(base: Player.Commands, setRunning: Boolean, itemCount: Int = 1): Player.Commands {
        val b = base.buildUpon()
        if (setRunning) b.addAll(*GATED) else if (itemCount <= 1) GATED.forEach { b.remove(it) }
        return b.build()
    }
}

/**
 * ForwardingPlayer that hides/shows next/prev/repeat/shuffle by [setRunning]. A flip pushes ONE
 * onAvailableCommandsChanged to the session's listeners; setting the same value is a no-op.
 */
open class SetGatedPlayer(player: Player) : ForwardingPlayer(player) {
    @Volatile var setRunning: Boolean = false
        private set

    private val listeners = CopyOnWriteArrayList<Player.Listener>()
    private val wrappers = java.util.concurrent.ConcurrentHashMap<Player.Listener, Player.Listener>()

    /** Rewrites the wrapped player's ungated onAvailableCommandsChanged into the gated set. */
    private inner class GatedListener(private val d: Player.Listener) : Player.Listener by d {
        override fun onAvailableCommandsChanged(availableCommands: Player.Commands) {
            d.onAvailableCommandsChanged(SetGate.apply(availableCommands, setRunning, mediaItemCount))
        }
    }

    /** Diffed update: returns true when the value changed (and listeners were told). */
    fun updateSetRunning(running: Boolean): Boolean {
        if (running == setRunning) return false
        setRunning = running
        val cmds = availableCommands
        listeners.forEach { it.onAvailableCommandsChanged(cmds) }
        return true
    }

    protected fun notifyListeners(block: (Player.Listener) -> Unit) = listeners.forEach(block)

    override fun getAvailableCommands(): Player.Commands = SetGate.apply(super.getAvailableCommands(), setRunning, mediaItemCount)

    override fun isCommandAvailable(command: Int): Boolean = availableCommands.contains(command)

    override fun addListener(listener: Player.Listener) {
        listeners += listener
        super.addListener(wrappers.getOrPut(listener) { GatedListener(listener) })
    }

    override fun removeListener(listener: Player.Listener) {
        listeners -= listener
        super.removeListener(wrappers.remove(listener) ?: listener)
    }
}
