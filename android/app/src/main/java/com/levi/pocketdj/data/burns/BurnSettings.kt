package com.levi.pocketdj.data.burns

/** Tunables + user-facing strings for the collection Rip/Burn bar (iOS `CollectionRipBurnController`). */
object BurnSettings {
    /** Rip-progress poll cadence and cap (~2 h at 4.5 s/tick); the poll never runs forever. */
    const val RIP_POLL_INTERVAL_MS = 4_500L
    const val RIP_POLL_MAX_TICKS = 1_600
    /** Collection Stemify progress poll (iOS stemPollIntervalMs/stemPollMaxTicks): ~4 h at 5 s. */
    const val STEM_POLL_INTERVAL_MS = 5_000L
    const val STEM_POLL_MAX_TICKS = 2_880

    /** Row note after a Burn for an un-ripped song (BurnStore's error text, matched verbatim). */
    const val NOT_RIPPED_FIRST = "not ripped — Rip first"
    const val NOT_RIPPED_NO_SERVER = "not ripped (no rip server)"

    const val FOLDER_UNAVAILABLE = "Couldn’t write to the burnt-music folder — check Settings"
}
