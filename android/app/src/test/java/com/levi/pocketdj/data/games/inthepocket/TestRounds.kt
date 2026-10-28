package com.levi.pocketdj.data.games.inthepocket

import java.util.UUID

/** Shared fixture builders (port of `InThePocketStoreTests.round`). */
internal object TestRounds {
    fun round(
        songs: List<String>, outcome: InThePocketOutcome?,
        targets: List<InThePocketTarget> = listOf(InThePocketTarget("genre", "funk", "Funk", 1.0)),
        context: InThePocketContext = InThePocketContext("evening", "weekday", 2, null),
    ) = InThePocketRound(
        id = UUID.randomUUID(), createdAtMs = 1_700_000_000_000.0, startedAtMs = 1_700_000_000_000.0,
        endedAtMs = if (outcome == null) null else 1_700_000_900_000.0, updatedAtMs = 1_700_000_900_000.0,
        tzOffsetMin = -420, context = context, contextLabel = null, mode = InThePocketMode.CLOUD,
        seed = "1", algoVersion = 1, targets = targets,
        songs = songs.map { InThePocketSong(it, it, "A-$it", null, 1.0, emptyList()) },
        outcome = outcome, rating = null, feedback = null, appVersion = "test",
    )
}
