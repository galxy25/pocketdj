package com.levi.pocketdj.shell

/**
 * Parks links that arrive before onboarding completes (iOS `pendingOpenURL` /
 * `pendingJukeboxLink` / `pendingMwFLink`). Insertion-ordered and de-duplicated: tapping the
 * same link twice parks it once, so it runs once on drain. [drain] is atomic — concurrent
 * drainers never see the same link twice.
 */
class PendingOpenStore {
    private val lock = Any()
    private val parked = LinkedHashSet<DeepLink>()

    /** @return true if newly parked, false if an equal link was already waiting. */
    fun park(link: DeepLink): Boolean = synchronized(lock) {
        if (link is DeepLink.None) false else parked.add(link)
    }

    /** Remove and return everything parked, oldest first. */
    fun drain(): List<DeepLink> = synchronized(lock) {
        parked.toList().also { parked.clear() }
    }

    val size: Int get() = synchronized(lock) { parked.size }
    fun isEmpty(): Boolean = size == 0
}
