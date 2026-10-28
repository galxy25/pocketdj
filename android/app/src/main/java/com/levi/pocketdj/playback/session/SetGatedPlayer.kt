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

    /** next/prev/repeat/shuffle exist only while a set is running; everything else passes through. */
    fun apply(base: Player.Commands, setRunning: Boolean): Player.Commands {
        val b = base.buildUpon()
        if (setRunning) b.addAll(*GATED) else GATED.forEach { b.remove(it) }
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

    /** Diffed update: returns true when the value changed (and listeners were told). */
    fun updateSetRunning(running: Boolean): Boolean {
        if (running == setRunning) return false
        setRunning = running
        val cmds = availableCommands
        listeners.forEach { it.onAvailableCommandsChanged(cmds) }
        return true
    }

    protected fun notifyListeners(block: (Player.Listener) -> Unit) = listeners.forEach(block)

    override fun getAvailableCommands(): Player.Commands = SetGate.apply(super.getAvailableCommands(), setRunning)

    override fun isCommandAvailable(command: Int): Boolean = availableCommands.contains(command)

    override fun addListener(listener: Player.Listener) {
        listeners += listener
        super.addListener(listener)
    }

    override fun removeListener(listener: Player.Listener) {
        listeners -= listener
        super.removeListener(listener)
    }
}
