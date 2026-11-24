package com.levi.pocketdj.playback.session

import android.os.Bundle
import androidx.media3.session.CommandButton
import androidx.media3.session.SessionCommand
import com.levi.pocketdj.data.recs.RecFeedbackStore
import com.levi.pocketdj.playback.sequencer.RepeatMode

/**
 * The notification / lock-screen / Android Auto transport buttons (iOS lock-screen + CarPlay Now Playing parity),
 * published with `MediaSession.setMediaButtonPreferences`. The decision is a pure function of [Input] ([specs]); the
 * Media3 [CommandButton]s are a thin mapping ([buttons]) so the button sets per state are JVM-testable.
 *
 *  - ♥: standalone-player owner only (a Mix-owned card passes `favoriteVisible=false`), via [FavoriteCommand].
 *  - shuffle + repeat: only while a set runs. Repeat shows the EFFECTIVE mode (a pocket run reads OFF, and the tap is
 *    inert because the sequencer refuses the change).
 *  - 👍/👎: only while there is a rec target, and always as a pair. 👎 never skips or pauses; a lit thumb's tap clears.
 */
object MediaButtonPrefs {
    const val ACTION_SHUFFLE = "pdj.shuffle"
    const val ACTION_REPEAT = "pdj.repeat"
    const val ACTION_REC_ACCEPT = "pdj.rec.accept"
    const val ACTION_REC_REJECT = "pdj.rec.reject"

    /** Trusted session commands registered in `onConnect`. */
    val commands: List<SessionCommand> by lazy {
        listOf(ACTION_SHUFFLE, ACTION_REPEAT, ACTION_REC_ACCEPT, ACTION_REC_REJECT).map { SessionCommand(it, Bundle.EMPTY) }
    }

    enum class Kind { FAVORITE, SHUFFLE, REPEAT, THUMB_UP, THUMB_DOWN }

    /** Everything the layout depends on. */
    data class Input(
        /** The ♥ is allowed (standalone owner, a song is current, seam installed). */
        val favoriteVisible: Boolean = false,
        val favoriteFilled: Boolean = false,
        /** A set/run is live in the sequencer (shuffle + repeat only exist then). */
        val runActive: Boolean = false,
        /** The EFFECTIVE repeat mode. */
        val repeat: RepeatMode = RepeatMode.OFF,
        val shuffle: Boolean = false,
        /** `NowPlayingFeedback.currentTarget() != null`. */
        val hasRecTarget: Boolean = false,
        val verdict: RecFeedbackStore.Verdict? = null,
    )

    /** One button, platform-free. [lit] is the on/filled state; [repeat] is set for [Kind.REPEAT]. */
    data class Spec(val kind: Kind, val action: String, val lit: Boolean, val repeat: RepeatMode? = null)

    fun specs(i: Input): List<Spec> = buildList {
        if (i.favoriteVisible) add(Spec(Kind.FAVORITE, FavoriteCommand.ACTION, i.favoriteFilled))
        if (i.runActive) {
            add(Spec(Kind.SHUFFLE, ACTION_SHUFFLE, i.shuffle))
            add(Spec(Kind.REPEAT, ACTION_REPEAT, i.repeat != RepeatMode.OFF, i.repeat))
        }
        if (i.hasRecTarget) {
            // All-or-nothing pair; only the verdict's own thumb is lit.
            add(Spec(Kind.THUMB_UP, ACTION_REC_ACCEPT, i.verdict == RecFeedbackStore.Verdict.ACCEPTED))
            add(Spec(Kind.THUMB_DOWN, ACTION_REC_REJECT, i.verdict == RecFeedbackStore.Verdict.REJECTED))
        }
    }

    fun buttons(i: Input): List<CommandButton> = specs(i).map(::button)

    fun button(s: Spec): CommandButton {
        if (s.kind == Kind.FAVORITE) return FavoriteCommand.button(s.lit)
        val (icon, label) = when (s.kind) {
            Kind.SHUFFLE -> (if (s.lit) CommandButton.ICON_SHUFFLE_ON else CommandButton.ICON_SHUFFLE_OFF) to
                (if (s.lit) "Shuffle on" else "Shuffle off")
            Kind.REPEAT -> when (s.repeat) {
                RepeatMode.ALL -> CommandButton.ICON_REPEAT_ALL to "Repeat all"
                RepeatMode.ONE -> CommandButton.ICON_REPEAT_ONE to "Repeat one"
                else -> CommandButton.ICON_REPEAT_OFF to "Repeat off"
            }
            Kind.THUMB_UP -> (if (s.lit) CommandButton.ICON_THUMB_UP_FILLED else CommandButton.ICON_THUMB_UP_UNFILLED) to "More like this"
            else -> (if (s.lit) CommandButton.ICON_THUMB_DOWN_FILLED else CommandButton.ICON_THUMB_DOWN_UNFILLED) to "Less like this"
        }
        return CommandButton.Builder(icon)
            .setDisplayName(label)
            .setSessionCommand(SessionCommand(s.action, Bundle.EMPTY))
            .build()
    }

    /** The verdict a rec action asks for; null for any other action. */
    fun verdictFor(action: String): RecFeedbackStore.Verdict? = when (action) {
        ACTION_REC_ACCEPT -> RecFeedbackStore.Verdict.ACCEPTED
        ACTION_REC_REJECT -> RecFeedbackStore.Verdict.REJECTED
        else -> null
    }

    /** The mode a repeat tap asks for (off -> all -> one -> off); the sequencer may refuse (pocket run). */
    fun nextRepeat(effective: RepeatMode): RepeatMode = effective.next

    /** Android Auto's head unit files as CarPlay does; the phone's notification/lock screen is the Now Playing card. */
    fun surfaceFor(controllerPackage: String): RecFeedbackStore.Surface =
        if (controllerPackage == AUTO_PACKAGE || controllerPackage == AUTO_PROJECTION_PACKAGE) RecFeedbackStore.Surface.CAR_PLAY
        else RecFeedbackStore.Surface.NOW_PLAYING

    private const val AUTO_PACKAGE = "com.google.android.projection.gearhead"
    private const val AUTO_PROJECTION_PACKAGE = "com.google.android.projection.gearhead.frx"
}
