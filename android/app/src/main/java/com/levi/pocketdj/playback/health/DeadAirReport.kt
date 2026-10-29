package com.levi.pocketdj.playback.health

import java.util.Locale

/**
 * Pure formatting of the dead-air KPI for Settings > Debug (iOS `DebugView.deadAirLabel` / `lastDays` /
 * `worstPairs`): Today, the previous days that had activity, and the worst transition pairs of today.
 */
object DeadAirReport {
    data class Row(val label: String, val value: String)

    /** "2.4% · 12s dead / 8 min · 1 gaps>=3s", or an em dash when nothing was active. */
    fun label(d: DeadAirMeter.Day): String {
        if (d.activeSeconds <= 0) return "—"
        return String.format(
            Locale.US, "%.1f%% · %.0fs dead / %.0f min · %d gaps≥3s",
            d.deadRatio * 100, d.deadSeconds, d.activeSeconds / 60, d.gapsOver3s,
        )
    }

    /** Up to [n] earlier days with activity, newest first (today excluded). */
    fun lastDays(n: Int, doc: DeadAirMeter.Document, todayKey: String): List<Pair<String, DeadAirMeter.Day>> =
        doc.days.filter { it.key != todayKey && it.value.activeSeconds > 0 }
            .toList().sortedByDescending { it.first }.take(n)

    /** The [n] pairs (default 4) that cost the most silent seconds. */
    fun worstPairs(d: DeadAirMeter.Day, n: Int = 4): List<Pair<String, DeadAirMeter.Pair>> =
        d.byPair.toList().sortedByDescending { it.second.seconds }.take(n)

    fun pairLabel(p: DeadAirMeter.Pair): String =
        String.format(Locale.US, "%d× avg %.1fs max %.0fs", p.n, p.seconds / maxOf(1, p.n), p.max)

    fun rows(doc: DeadAirMeter.Document, todayKey: String, days: Int = 7): List<Row> {
        val today = doc.days[todayKey] ?: DeadAirMeter.Day()
        val out = mutableListOf(Row("Today", label(today)))
        lastDays(days, doc, todayKey).forEach { out += Row(it.first, label(it.second)) }
        worstPairs(today).forEach { out += Row(it.first, pairLabel(it.second)) }
        return out
    }

    /** Multi-line text for the Debug panel's 1 s refresh. */
    fun summary(meter: DeadAirMeter, nowMs: Long = System.currentTimeMillis()): String {
        val key = meter.dayKey(nowMs)
        return rows(meter.document, key).joinToString("\n") { "${it.label}: ${it.value}" }
    }
}
