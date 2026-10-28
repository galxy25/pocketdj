package com.levi.pocketdj.ui.dnd

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.PointerEventPass
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.levi.pocketdj.data.collections.SongTransfer
import com.levi.pocketdj.ui.selection.SelectionBarSemantics

/** How a hovered drop target shows itself: a filled row (collection rows) or an outline (whole lists). */
enum class DropHighlight { ROW, LIST }

/** Pure helpers behind the Compose DnD glue (JVM-testable). */
object SongDragSemantics {
    /** Drag chip text: "3 songs" / "1 song". */
    fun chipLabel(count: Int): String = if (count == 1) "1 song" else "$count songs"

    /** Both the drag and the clipboard carry the same two-item clip (text fallback, then JSON). */
    fun clipTexts(t: SongTransfer): List<String>? =
        SelectionBarSemantics.clipPayloadOrNull(t)?.let { listOf(it.first, it.second) }

    /** Drag distance (px) past which a long-pressed row actually starts the transfer. */
    fun movedPastSlop(dx: Float, dy: Float, slop: Float): Boolean = dx * dx + dy * dy > slop * slop

    /** Spring-loading: hover time before a drag over a nav item switches to that tab. */
    const val SPRING_LOAD_MS = 600L

    /** A drag hovering the already-selected tab does nothing. */
    fun shouldSpringLoad(alreadySelected: Boolean): Boolean = !alreadySelected

    /** Pasting outcome copy (iOS performPaste is silent; here "nothing" vs "already there" differ). */
    fun pasteMessage(hadPayload: Boolean, added: Boolean): String = when {
        !hadPayload -> "Nothing to paste"
        added -> "Pasted songs"
        else -> "Already in this collection"
    }

    /** Decode a drop's clip; null for anything that is not our payload. */
    fun decodeClip(label: CharSequence?, texts: List<String>): SongTransfer? =
        SongTransfer.fromClipTexts(label, texts)
}

/** Small label-only clip for an in-app drag: the payload itself rides in `localState` (no size cap). */
private fun dragClipOf(t: SongTransfer): ClipData =
    ClipData.newPlainText(SongTransfer.CLIP_LABEL, SongDragSemantics.chipLabel(t.songIds.size))

private fun DragAndDropEvent.songTransfer(): SongTransfer? {
    (toAndroidDragEvent().localState as? SongTransfer)?.let { return it }
    val clip = toAndroidDragEvent().clipData ?: return null
    val texts = (0 until clip.itemCount).map { clip.getItemAt(it).text?.toString().orEmpty() }
    return SongDragSemantics.decodeClip(clip.description?.label, texts)
}

/** Cheap clipboard probe (label only - never reads the contents, so no paste toast). */
fun clipboardHasSongs(context: Context): Boolean {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return false
    return runCatching { cm.primaryClipDescription?.label?.toString() == SongTransfer.CLIP_LABEL }.getOrDefault(false)
}

/**
 * Long-press-then-drag source for a SELECTED row (iOS: the selection is the drag payload).
 * In-app only (no GLOBAL flag), so a payload never leaks to other apps. [payload] is read at
 * drag start; null / unclipable (too big) payloads simply don't start a drag.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.songDragSource(enabled: Boolean, payload: () -> SongTransfer?): Modifier {
    val payloadL by rememberUpdatedState(payload)
    val accent = MaterialTheme.colorScheme.primary
    val fg = MaterialTheme.colorScheme.onPrimary
    if (!enabled) return this
    return this.dragAndDropSource(
        drawDragDecoration = {
            val t = payloadL()
            val label = SongDragSemantics.chipLabel(t?.songIds?.size ?: 1)
            val w = size.width.coerceAtLeast(1f)
            val h = size.height.coerceAtLeast(1f)
            drawRoundRect(accent.copy(alpha = 0.85f), size = Size(w, h), cornerRadius = CornerRadius(h / 2))
            drawIntoCanvas { c ->
                val paint = android.graphics.Paint().apply {
                    isAntiAlias = true
                    color = android.graphics.Color.argb(
                        (fg.alpha * 255).toInt(), (fg.red * 255).toInt(), (fg.green * 255).toInt(), (fg.blue * 255).toInt(),
                    )
                    textSize = (h * 0.4f).coerceAtMost(48f)
                    textAlign = android.graphics.Paint.Align.CENTER
                }
                c.nativeCanvas.drawText(label, w / 2, h / 2 + paint.textSize / 3, paint)
            }
        },
    ) {
        // The system drag starts only once the finger moves past touch slop AFTER the long-press,
        // so a stationary long-press keeps the row's own long-click (Add-to menu / select toggle).
        val slop = viewConfiguration.touchSlop
        // Initial pass: the row's own combinedClickable (a child) consumes the move events after its
        // long-click fires, so a Main-pass detector never saw the drag (emulator-verified).
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            val id = down.id
            val cancelled = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                while (true) {
                    val ev = awaitPointerEvent(PointerEventPass.Initial)
                    val c = ev.changes.firstOrNull { it.id == id } ?: return@withTimeoutOrNull true
                    if (!c.pressed) return@withTimeoutOrNull true
                    val d = c.position - down.position
                    if (SongDragSemantics.movedPastSlop(d.x, d.y, slop)) return@withTimeoutOrNull true
                }
                @Suppress("UNREACHABLE_CODE") false
            }
            if (cancelled == true) return@awaitEachGesture
            while (true) {
                val ev = awaitPointerEvent(PointerEventPass.Initial)
                val c = ev.changes.firstOrNull { it.id == id } ?: return@awaitEachGesture
                if (!c.pressed) return@awaitEachGesture
                val d = c.position - down.position
                if (SongDragSemantics.movedPastSlop(d.x, d.y, slop)) {
                    val t = payloadL()
                    if (t != null && t.songIds.isNotEmpty()) {
                        c.consume()
                        startTransfer(DragAndDropTransferData(clipData = dragClipOf(t), localState = t, flags = 0))
                    }
                    return@awaitEachGesture
                }
            }
        }
    }
}

/**
 * Registry behind [songDropTarget]. Compose DnD only offers a drag to targets that existed when the
 * drag STARTED, so targets composed after a spring-load tab switch would never get the drop. One
 * root target ([songDropRoot], always composed) therefore routes every drop by pointer position to
 * the registered entries (smallest containing bounds wins).
 */
object SongDropRegistry {
    class Entry(
        val bounds: () -> androidx.compose.ui.geometry.Rect?,
        val onHover: (Boolean) -> Unit,
        val onDrop: (SongTransfer) -> Boolean,
    )

    private val entries = java.util.concurrent.CopyOnWriteArrayList<Entry>()
    private var hovered: Entry? = null

    fun register(e: Entry) { entries.add(e) }
    fun unregister(e: Entry) { entries.remove(e); if (hovered === e) hovered = null }

    fun entryAt(x: Float, y: Float): Entry? = entries
        .mapNotNull { e -> e.bounds()?.takeIf { it.contains(Offset(x, y)) }?.let { e to it.width * it.height } }
        .minByOrNull { it.second }?.first

    fun hoverAt(x: Float, y: Float) {
        val e = entryAt(x, y)
        if (e === hovered) return
        hovered?.onHover?.invoke(false)
        hovered = e
        e?.onHover?.invoke(true)
    }

    fun clearHover() { hovered?.onHover?.invoke(false); hovered = null }

    fun dropAt(x: Float, y: Float, t: SongTransfer): Boolean {
        val e = entryAt(x, y)
        clearHover()
        return e?.onDrop?.invoke(t) ?: false
    }
}

/** Always-composed root drop target: routes song drops to the [SongDropRegistry] entry under the pointer. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.songDropRoot(): Modifier {
    val target = remember {
        object : DragAndDropTarget {
            override fun onMoved(event: DragAndDropEvent) {
                val a = event.toAndroidDragEvent(); SongDropRegistry.hoverAt(a.x, a.y)
            }
            override fun onExited(event: DragAndDropEvent) { SongDropRegistry.clearHover() }
            override fun onEnded(event: DragAndDropEvent) { SongDropRegistry.clearHover() }
            override fun onDrop(event: DragAndDropEvent): Boolean {
                val t = event.songTransfer() ?: return false
                val a = event.toAndroidDragEvent()
                return SongDropRegistry.dropAt(a.x, a.y, t)
            }
        }
    }
    return this.dragAndDropTarget(
        shouldStartDragAndDrop = { ev ->
            ev.toAndroidDragEvent().clipDescription?.label?.toString() == SongTransfer.CLIP_LABEL
        },
        target = target,
    )
}

/**
 * Drop target for song payloads. [onDrop] gets the decoded transfer (already refused if foreign /
 * oversize) and returns whether anything was added. The highlight shows ONLY while a song payload
 * hovers the target. Folder headers / source rows simply never attach this modifier.
 * Routed through [SongDropRegistry] (see there for why).
 */
@Composable
fun Modifier.songDropTarget(
    enabled: Boolean = true,
    highlight: DropHighlight = DropHighlight.ROW,
    onDrop: (SongTransfer) -> Boolean,
): Modifier {
    if (!enabled) return this
    val dropL by rememberUpdatedState(onDrop)
    var hovered by remember { mutableStateOf(false) }
    val accent = MaterialTheme.colorScheme.primary
    var coords by remember { mutableStateOf<androidx.compose.ui.layout.LayoutCoordinates?>(null) }
    androidx.compose.runtime.DisposableEffect(Unit) {
        val e = SongDropRegistry.Entry(
            bounds = { coords?.takeIf { it.isAttached }?.boundsInRoot() },
            onHover = { hovered = it },
            onDrop = { t -> hovered = false; dropL(t) },
        )
        SongDropRegistry.register(e)
        onDispose { SongDropRegistry.unregister(e) }
    }
    return this
        .androidx_onPlaced { coords = it }
        .let {
            if (!hovered) it else when (highlight) {
                DropHighlight.ROW -> it.background(accent.copy(alpha = 0.18f))
                DropHighlight.LIST -> it.drawWithContent {
                    drawContent()
                    val inset = 4.dp.toPx()
                    drawRoundRect(
                        accent,
                        topLeft = Offset(inset, inset),
                        size = Size(size.width - 2 * inset, size.height - 2 * inset),
                        cornerRadius = CornerRadius(8.dp.toPx()),
                        style = Stroke(2.dp.toPx()),
                    )
                }
            }
        }
}

private fun Modifier.androidx_onPlaced(f: (androidx.compose.ui.layout.LayoutCoordinates) -> Unit): Modifier =
    this.onGloballyPositioned(f)

/** Drop/paste onto a whole collection: default chapter / the pocket, resolve-gated, ONE addSongs call. */
fun acceptSongsInto(
    store: com.levi.pocketdj.data.collections.CollectionsStore,
    target: com.levi.pocketdj.data.collections.AddTarget,
    t: SongTransfer,
): Boolean = com.levi.pocketdj.data.collections.SongDrop.accept(listOf(t), store::songResolves) {
    store.addSongs(it, target)
}

/**
 * The "Paste songs" menu action: reads the clip (label-gated, byte-capped) and adds to [target].
 * Foreign clipboard text decodes to null and is a silent no-op (nothing persisted).
 */
fun pasteSongsInto(
    context: Context,
    store: com.levi.pocketdj.data.collections.CollectionsStore,
    target: com.levi.pocketdj.data.collections.AddTarget,
): Boolean {
    val t = com.levi.pocketdj.ui.selection.readSongTransfer(context)
    val ok = t != null && acceptSongsInto(store, target, t)
    android.widget.Toast.makeText(context, SongDragSemantics.pasteMessage(t != null, ok), android.widget.Toast.LENGTH_SHORT).show()
    return ok
}

/**
 * Spring-loaded nav item: a song drag hovering this item for [SongDragSemantics.SPRING_LOAD_MS]
 * switches to its tab ([onSpring]) so the live drag can carry on into that tab's drop targets
 * (the system drag survives the recomposition). Accepts no drop itself.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.springLoadTarget(alreadySelected: Boolean, onSpring: () -> Unit): Modifier {
    val springL by rememberUpdatedState(onSpring)
    val selectedL by rememberUpdatedState(alreadySelected)
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val target = remember {
        var job: kotlinx.coroutines.Job? = null
        object : DragAndDropTarget {
            override fun onEntered(event: DragAndDropEvent) {
                job?.cancel()
                if (!SongDragSemantics.shouldSpringLoad(selectedL)) return
                job = scope.launch {
                    delay(SongDragSemantics.SPRING_LOAD_MS)
                    springL()
                }
            }
            override fun onExited(event: DragAndDropEvent) { job?.cancel() }
            override fun onEnded(event: DragAndDropEvent) { job?.cancel() }
            override fun onDrop(event: DragAndDropEvent): Boolean { job?.cancel(); return false }
        }
    }
    return this.dragAndDropTarget(
        shouldStartDragAndDrop = { ev ->
            ev.toAndroidDragEvent().clipDescription?.label?.toString() == SongTransfer.CLIP_LABEL
        },
        target = target,
    )
}
