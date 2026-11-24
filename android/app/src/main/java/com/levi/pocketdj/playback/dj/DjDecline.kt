package com.levi.pocketdj.playback.dj

/**
 * DJ Mode's ONE decline list (iOS `SetlistPlayer.djEndReason` + the `next not local` check of `djMakeTransition`).
 * The SAME function feeds the decision at the lead window, the re-check at the fade start, a skip's decision (P2-DJ-9)
 * and the Now Playing chip, so the three can never disagree about whether this song's end will mix. Pure.
 *
 * The engine's own reasons (not playing, growing outgoing, stems muted, unreadable incoming, too close to the end: see
 * [com.levi.pocketdj.mix.nowplaying.DjEngineDecline]) are added by the engine when the begin is attempted; [engineWords]
 * gives their chip words.
 */
object DjDecline {
    enum class Reason(val raw: String, val end: DjEndReason) {
        TRANSITIONS_OFF("transitions off", DjEndReason.TRANSITIONS_OFF),
        REPEATING("repeat", DjEndReason.REPEATING),
        HALTED("halted", DjEndReason.HALTED),
        LAST_SONG("last song", DjEndReason.LAST_SONG),
        SET_REPEATS("set repeats", DjEndReason.SET_REPEATS),
        ALBUM_RUN("album run", DjEndReason.ALBUM_RUN),
        ALBUM_STARTS("next starts an album side", DjEndReason.ALBUM_STARTS),

        /** The CURRENT row is not on the DSP (Apple Music / live capture / not a local file / the DSP refused it). */
        PLAIN("plain row", DjEndReason.PLAIN),

        /** The next row is not a complete local file (yet): the song ends as it does today. */
        NEXT_NOT_LOCAL("next not local", DjEndReason.PLAIN);

        /** The Now Playing Mix panel's DJ status for this reason. */
        val indicator: DjMode.Indicator get() = DjEndReason.indicator(end)
    }

    /** Everything the list is a pure function of; the conductor reads each from the sequencer / DSP at the moment. */
    data class Inputs(
        /** There is a current row (false = nothing to end). */
        val hasCurrent: Boolean = true,
        /** Settings ▸ Mixing ▸ DJ transitions. */
        val transitionsOn: Boolean = true,
        val repeatOne: Boolean = false,
        /** Plays left of the current row (> 1 = a per-row repeat count is running). */
        val playsRemaining: Int = 1,
        /** The cascade breaker / auto-advance gate halted the run. */
        val halted: Boolean = false,
        /** A row follows the current one in the queue. */
        val hasNext: Boolean = true,
        val repeatAll: Boolean = false,
        /** The current row plays through a shared album side with the next song following in order. */
        val albumRunPlaying: Boolean = false,
        /** The NEXT row starts an album run (its side glides on the record). */
        val nextStartsAlbumRun: Boolean = false,
        /** The current row sits on the DSP (the transition engine can act). */
        val dspEngaged: Boolean = true,
        /** The next row is a complete local file; null = not asked (the fade-start re-check, the chip). */
        val nextLocal: Boolean? = null,
    )

    /**
     * The first reason this song's end will NOT be a DJ transition, null = it will. [forSkip] (a ⏭): an explicit skip
     * overrides repeat-one / a repeat count and is itself the listener lifting a cascade halt, so those two are skipped.
     */
    fun reason(i: Inputs, forSkip: Boolean = false): Reason? {
        if (!i.hasCurrent) return Reason.LAST_SONG
        if (!i.transitionsOn) return Reason.TRANSITIONS_OFF
        if (!forSkip) {
            if (i.repeatOne || i.playsRemaining > 1) return Reason.REPEATING
            if (i.halted) return Reason.HALTED
        }
        if (!i.hasNext) return if (i.repeatAll) Reason.SET_REPEATS else Reason.LAST_SONG
        if (i.albumRunPlaying) return Reason.ALBUM_RUN
        if (i.nextStartsAlbumRun) return Reason.ALBUM_STARTS
        if (!i.dspEngaged) return Reason.PLAIN
        if (i.nextLocal == false) return Reason.NEXT_NOT_LOCAL
        return null
    }

    /** The log string of a decline: a skip's reasons are prefixed (iOS `skip: <reason>`). */
    fun logWords(raw: String, forSkip: Boolean): String = if (forSkip) "skip: $raw" else raw

    /** Chip words for an ENGINE-side decline string (`DjEngineDecline`): the sequencer words never overlap with these. */
    fun engineWords(raw: String): String = when (raw) {
        com.levi.pocketdj.mix.nowplaying.DjEngineDecline.GROWING -> "still downloading"
        com.levi.pocketdj.mix.nowplaying.DjEngineDecline.STEMS_MUTED -> "stems muted"
        com.levi.pocketdj.mix.nowplaying.DjEngineDecline.STEM_HANDOVER -> "stems loading"
        com.levi.pocketdj.mix.nowplaying.DjEngineDecline.INCOMING_UNREADABLE -> "next can't be read"
        com.levi.pocketdj.mix.nowplaying.DjEngineDecline.TOO_CLOSE -> "too close to the end"
        com.levi.pocketdj.mix.nowplaying.DjEngineDecline.NOT_PLAYING -> "not playing"
        else -> raw
    }
}
