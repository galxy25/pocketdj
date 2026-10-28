package com.levi.pocketdj.playback.sequencer

/**
 * WHY the set is advancing (the cascade breaker's input).
 * - [USER]: a transport the listener pressed.
 * - [AUTO]: the sequencer moved on by itself (end of track, dead source, a stream that never
 *   started) - counted by the breaker.
 * - [UNPLAYABLE_HERE]: a row this device cannot play at all (device mode with no burned file, a
 *   metadata-only row): an instant, deliberate skip, neither counted nor resetting.
 */
enum class AdvanceCause { USER, AUTO, UNPLAYABLE_HERE }
