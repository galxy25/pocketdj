package com.levi.pocketdj.data.jukebox

/** Pure jukebox Settings/copy helpers. */
object JukeboxSettings {
    /** iOS `JukeboxView.defaultName`: "<DJ>'s Jukebox" when the PocketDJ name is set. */
    fun defaultSessionName(pocketDjName: String): String {
        val dj = pocketDjName.trim()
        return if (dj.isEmpty()) JukeboxRepository.DEFAULT_SESSION_NAME else "$dj's Jukebox"
    }

    const val REQUIRE_TOKEN_TITLE = "Require access tokens by default"

    /** Spec §9: the token is intent only — copy must never claim the link is gated. */
    const val REQUIRE_TOKEN_CAPTION =
        "Seeds the Jukebox create view. Saved with each session as an intent for a " +
            "future guest-access gate; links are not access-controlled today."
}
