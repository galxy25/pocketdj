package com.levi.pocketdj.shell

/**
 * Parks links that arrive before onboarding completes. Like iOS (`pendingOpenURL` /
 * `pendingJukeboxLink` / `pendingMwFLink`) there is one slot per link kind and the newest link
 * of a kind wins. [drain] is atomic and returns slots in first-parked order.
 */
class PendingOpenStore {
    private val lock = Any()
    private val slots = LinkedHashMap<String, DeepLink>()

    private fun kind(link: DeepLink): String = when (link) {
        is DeepLink.JukeboxJoin -> "jukebox"
        is DeepLink.Mwf -> "mwf"
        is DeepLink.CollectionFile -> "file"
        else -> "open" // Play / Navigate share iOS's single pendingOpenURL
    }

    /** @return true if the slot changed, false if an equal link was already waiting. */
    fun park(link: DeepLink): Boolean = synchronized(lock) {
        if (link is DeepLink.None || link is DeepLink.DiagKey) return false
        val k = kind(link)
        if (slots[k] == link) return false
        slots.remove(k) // newest re-enters at the end
        slots[k] = link
        true
    }

    /** Remove and return everything parked, oldest slot first. */
    fun drain(): List<DeepLink> = synchronized(lock) {
        slots.values.toList().also { slots.clear() }
    }

    val size: Int get() = synchronized(lock) { slots.size }
    fun isEmpty(): Boolean = size == 0
}
