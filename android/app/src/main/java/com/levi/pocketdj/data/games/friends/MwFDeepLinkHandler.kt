package com.levi.pocketdj.data.games.friends

import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.shell.DeepLink
import com.levi.pocketdj.shell.DeepLinkSeams
import com.levi.pocketdj.shell.ShellRoute

/**
 * Games-side consumer of `pocketdj://mwf/<id>` and `https://jukebox.pocket-dj.com/mwf/<id>/` links
 * (iOS `RootView` `pendingMwFLink` -> `friends.handleOpenedLink`). The shell's dispatcher parses and
 * gates on onboarding, then calls the `mwf` seam; this raises the store's open/join signals and
 * lands on the Games tab, where the screen reacts (known session pushes it, unknown opens the Join sheet).
 */
class MwFDeepLinkHandler(
    private val openLink: (MwFLink) -> Unit,
    private val postRoute: (ShellRoute) -> Unit,
) {
    /** Seam entry (already-parsed [DeepLink.Mwf]). Returns false when the id is not a valid session id. */
    fun open(link: DeepLink.Mwf): Boolean {
        if (!MwFLink.isValidId(link.id)) return false
        openLink(MwFLink(link.id, link.guestBase))
        postRoute(ShellRoute.Tab(PocketDjDestination.Games))
        return true
    }

    /** Raw-URL entry (tests, debug). */
    fun openUrl(raw: String): Boolean {
        val link = MwFLink.parse(raw) ?: return false
        openLink(link)
        postRoute(ShellRoute.Tab(PocketDjDestination.Games))
        return true
    }

    /** Claim the dispatcher's `mwf` seam; replays a link that arrived before we claimed it. */
    fun install(seams: DeepLinkSeams, takePending: () -> DeepLink.Mwf?) {
        seams.mwf = { open(it) }
        takePending()?.let { open(it) }
    }
}
