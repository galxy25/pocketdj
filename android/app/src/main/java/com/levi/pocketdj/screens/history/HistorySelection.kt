package com.levi.pocketdj.screens.history

/** Pure helpers for History multi-select (ids are play-event ids; payloads are song ids). */
internal object HistorySelection {
    const val SCOPE = "history-playback"

    /**
     * Song ids for the selected events in DISPLAY order, de-duplicated (the same song played twice and
     * selected twice shares once). [orderedEvents] is (eventId, songId) in display order.
     */
    fun songIds(selectedEventIds: Set<String>, orderedEvents: List<Pair<String, String>>): List<String> =
        orderedEvents.asSequence()
            .filter { it.first in selectedEventIds }
            .map { it.second }
            .distinct()
            .toList()
}
