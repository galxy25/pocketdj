package com.levi.pocketdj.data.games

/** Constants shared by the Games area (file names, debug seam keys). */
object GamesPrefs {
    /** iOS file name; CloudKit/profile sync unions it by run id. */
    const val SCOREBOARD_FILE = "pocketdj-game-scores.json"
    const val SCOREBOARD_SYNC_KEY = "game-scores"

    /** Debug-only launch extra (`-e pdj.seedGames true`) that seeds the scoreboard fixture. */
    const val SEED_EXTRA = "pdj.seedGames"
    /** Debug: explicit opt-in for a REPLACING seed (wipes real history); absent = polite no-op seed. */
    const val USE_FIXTURE_EXTRA = "pdj.useFixture"
}
