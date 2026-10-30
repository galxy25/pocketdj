package com.levi.pocketdj.shell

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * The `pocketdj://play/<kind>/<id>` seam: every kind plays through [ShellActions] (same code the
 * Assistant uses) and failures surface as a message. Returns null (the dispatcher opens nothing).
 * [onLaunched] is a test hook exposing the launched job.
 */
fun playLinkSeam(
    actions: ShellActions,
    scope: CoroutineScope,
    onLaunched: (Job) -> Unit = {},
    postMessage: (String) -> Unit,
): (PlayKind, String, Boolean) -> String? = { kind, id, shuffle ->
    onLaunched(
        scope.launch {
            try {
                when (kind) {
                    PlayKind.Playlist -> actions.playPlaylist(id, shuffle)
                    PlayKind.Pocket -> actions.playPocket(id, shuffle)
                    PlayKind.Setlist -> actions.playSetlist(id, shuffle)
                    PlayKind.Album -> actions.playAlbum(id, shuffle)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                postMessage((e as? ShellActionException)?.message ?: "Couldn't play that.")
            }
        },
    )
    null
}
