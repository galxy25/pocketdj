package com.levi.pocketdj.playback.sequencer

/**
 * WHY the set is advancing (the cascade breaker's input).
 * - [USER]: a transport the listener pressed.
 * - [NATURAL_END]: the track played through (counted by the breaker).
 * - [AUTO_SKIP]: the sequencer moved on by itself because the row was dead (a failed load, a stream that never
 *   started, a mid-song failure) - counted by the breaker.
 * - [STALL_HOP]: a stalled start advanced past (no on-device / instant row to hop to) - counted by the breaker.
 * - [UNPLAYABLE_HERE]: a row this device cannot play at all (device mode with no burned file, a
 *   metadata-only row): an instant, deliberate skip, neither counted nor resetting.
 *
 * (Before parity-2 the three automatic causes were one `AUTO`.)
 */
enum class AdvanceCause {
    USER, NATURAL_END, AUTO_SKIP, STALL_HOP, UNPLAYABLE_HERE;

    /** The sequencer moved by itself: gated by [SetlistSequencer.autoAdvanceGate] and counted by the cascade breaker. */
    val isAuto: Boolean get() = this == NATURAL_END || this == AUTO_SKIP || this == STALL_HOP

    fun toTransitionCause(): TransitionCause = when (this) {
        USER -> TransitionCause.USER
        NATURAL_END -> TransitionCause.NATURAL_END
        AUTO_SKIP -> TransitionCause.AUTO_SKIP
        STALL_HOP -> TransitionCause.STALL_HOP
        UNPLAYABLE_HERE -> TransitionCause.UNPLAYABLE
    }
}

/**
 * Why the CURRENT row changed (iOS `SetlistPlayer.TransitionCause`), recorded on every current-row change.
 * [REMOTE] is a change applied on behalf of another device (set via [SetlistSequencer.applyingCause]).
 */
enum class TransitionCause { USER, NATURAL_END, AUTO_SKIP, STALL_HOP, UNPLAYABLE, REMOTE }
