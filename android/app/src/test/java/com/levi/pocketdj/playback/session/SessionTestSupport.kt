package com.levi.pocketdj.playback.session

import androidx.media3.common.Player
import com.levi.pocketdj.playback.sequencer.RepeatMode
import java.lang.reflect.Proxy

/** A Player stub (dynamic proxy) with a recorded call list and a few configurable answers. */
class FakePlayerState {
    var state = Player.STATE_READY
    var items = 1
    var playWhenReady = false
    val calls = mutableListOf<String>()
    var baseCommands: Player.Commands = Player.Commands.Builder().addAllCommands().build()
}

fun fakePlayer(s: FakePlayerState): Player =
    Proxy.newProxyInstance(Player::class.java.classLoader, arrayOf(Player::class.java)) { _, m, args ->
        s.calls += m.name
        when (m.name) {
            "getPlaybackState" -> s.state
            "getMediaItemCount" -> s.items
            "getPlayWhenReady" -> s.playWhenReady
            "getAvailableCommands" -> s.baseCommands
            "isCommandAvailable" -> s.baseCommands.contains(args[0] as Int)
            "hasNextMediaItem", "hasPreviousMediaItem" -> false
            "getRepeatMode" -> Player.REPEAT_MODE_OFF
            "getShuffleModeEnabled" -> false
            else -> when (m.returnType) {
                java.lang.Boolean.TYPE -> false
                Integer.TYPE -> 0
                java.lang.Long.TYPE -> 0L
                else -> null
            }
        }
    } as Player

class FakeControl : SequencerControl {
    override var isRunning = false
    override var isHeldForResume = false
    override var isStartPending = false
    override var currentNeverSounded = false
    override var repeatMode = RepeatMode.OFF
    override var shuffleEnabled = false
    val calls = mutableListOf<String>()
    override fun skipNext() { calls += "next" }
    override fun skipPrevious() { calls += "prev" }
    override fun resumeFromHold() { calls += "resumeHeld" }
    override fun startCurrent(): Boolean { calls += "startCurrent"; return true }
}
