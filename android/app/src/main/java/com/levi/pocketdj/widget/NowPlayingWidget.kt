package com.levi.pocketdj.widget

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.KeyEvent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionSendBroadcast
import androidx.glance.appwidget.action.actionStartService
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.levi.pocketdj.R

/** Which layout a given widget box gets. Pure so the size policy is testable. */
enum class WidgetSizeClass {
    Small, Medium, Large;

    companion object {
        fun of(widthDp: Float, heightDp: Float): WidgetSizeClass = when {
            heightDp >= 220f && widthDp >= 200f -> Large
            widthDp >= 200f -> Medium
            else -> Small
        }
    }
}

/** What the large widget lists / the ♥ shows; pure derivations over the snapshot. */
object WidgetModel {
    fun showHeart(s: NowPlayingSnapshot) = s.hasContent && s.favoriteAvailable && !s.songId.isNullOrEmpty()
    fun repeatNext(s: NowPlayingSnapshot): String = when (s.repeatMode) { "off" -> "all"; "all" -> "one"; else -> "off" }
    fun rows(s: NowPlayingSnapshot) = s.upNext.take(WidgetSync.UP_NEXT_MAX)
}

class NowPlayingWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM, LARGE))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val store = WidgetFiles.snapshotStore(context)
        val snap = store.read()
        val cover = if (snap.hasContent) loadCover(store) else null
        provideContent { Content(context, snap, cover) }
    }

    @Composable
    private fun Content(ctx: Context, s: NowPlayingSnapshot, cover: Bitmap?) {
        val size = LocalSize.current
        val bg = GlanceModifier.fillMaxSize().background(BG).cornerRadius(20.dp)
            .clickable(actionStartActivity(ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: Intent()))
        Box(bg.padding(10.dp), contentAlignment = Alignment.Center) {
            if (!s.hasContent) {
                Idle(ctx)
            } else when (WidgetSizeClass.of(size.width.value, size.height.value)) {
                WidgetSizeClass.Small -> Small(ctx, s, cover)
                WidgetSizeClass.Medium -> Medium(ctx, s, cover)
                WidgetSizeClass.Large -> Large(ctx, s, cover)
            }
        }
    }

    @Composable
    private fun Idle(ctx: Context) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = GlanceModifier.fillMaxWidth()) {
            Image(ImageProvider(R.drawable.ic_widget_note), null, GlanceModifier.size(32.dp), colorFilter = ColorFilter.tint(DIM))
            Spacer(GlanceModifier.width(10.dp))
            Column(GlanceModifier.defaultWeight()) {
                Text("Nothing playing", style = TextStyle(color = FG, fontSize = 14.sp, fontWeight = FontWeight.Medium), maxLines = 1)
                Text("Tap to open PocketDJ", style = TextStyle(color = DIM, fontSize = 11.sp), maxLines = 1)
            }
            Btn(R.drawable.ic_widget_play, "Play", key(ctx, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        }
    }

    @Composable
    private fun Small(ctx: Context, s: NowPlayingSnapshot, cover: Bitmap?) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = GlanceModifier.fillMaxWidth()) {
            Cover(cover, 44.dp)
            Spacer(GlanceModifier.defaultWeight())
            Btn(playGlyph(s), "Play or pause", key(ctx, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
            Btn(R.drawable.ic_widget_next, "Next", key(ctx, KeyEvent.KEYCODE_MEDIA_NEXT))
        }
    }

    @Composable
    private fun Medium(ctx: Context, s: NowPlayingSnapshot, cover: Bitmap?) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = GlanceModifier.fillMaxWidth()) {
            Cover(cover, 72.dp)
            Spacer(GlanceModifier.width(10.dp))
            Column(GlanceModifier.defaultWeight()) {
                TitleBlock(s)
                Spacer(GlanceModifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Btn(R.drawable.ic_widget_previous, "Previous", key(ctx, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
                    Btn(playGlyph(s), "Play or pause", key(ctx, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
                    Btn(R.drawable.ic_widget_next, "Next", key(ctx, KeyEvent.KEYCODE_MEDIA_NEXT))
                    if (WidgetModel.showHeart(s)) Heart(ctx, s)
                }
            }
        }
    }

    @Composable
    private fun Large(ctx: Context, s: NowPlayingSnapshot, cover: Bitmap?) {
        Column(GlanceModifier.fillMaxSize()) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = GlanceModifier.fillMaxWidth()) {
                Cover(cover, 84.dp)
                Spacer(GlanceModifier.width(12.dp))
                Column(GlanceModifier.defaultWeight()) { TitleBlock(s) }
            }
            Spacer(GlanceModifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically, modifier = GlanceModifier.fillMaxWidth()) {
                Btn(R.drawable.ic_widget_previous, "Previous", key(ctx, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
                Btn(playGlyph(s), "Play or pause", key(ctx, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
                Btn(R.drawable.ic_widget_next, "Next", key(ctx, KeyEvent.KEYCODE_MEDIA_NEXT))
                if (WidgetModel.showHeart(s)) Heart(ctx, s)
                Btn(
                    if (s.repeatMode == "one") R.drawable.ic_widget_repeat_one else R.drawable.ic_widget_repeat,
                    "Repeat",
                    cmd(ctx, WidgetCommand.Kind.REPEAT, s, WidgetModel.repeatNext(s)),
                    tint = if (s.repeatMode == "off") DIM else ACCENT,
                )
                Btn(
                    R.drawable.ic_widget_shuffle, "Shuffle",
                    cmd(ctx, WidgetCommand.Kind.SHUFFLE, s, if (s.shuffleEnabled) "0" else "1"),
                    tint = if (s.shuffleEnabled) ACCENT else DIM,
                )
            }
            val rows = WidgetModel.rows(s)
            if (rows.isNotEmpty()) {
                Spacer(GlanceModifier.height(6.dp))
                Text("UP NEXT", style = TextStyle(color = DIM, fontSize = 10.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                rows.forEach { t ->
                    Text(
                        "${t.title} - ${t.artist}",
                        style = TextStyle(color = FG, fontSize = 12.sp), maxLines = 1,
                        modifier = GlanceModifier.fillMaxWidth().padding(vertical = 1.dp),
                    )
                }
            }
        }
    }

    @Composable
    private fun TitleBlock(s: NowPlayingSnapshot) {
        Text(s.title, style = TextStyle(color = FG, fontSize = 15.sp, fontWeight = FontWeight.Bold), maxLines = 2)
        Text(s.artist, style = TextStyle(color = DIM, fontSize = 12.sp), maxLines = 1)
    }

    @Composable
    private fun Heart(ctx: Context, s: NowPlayingSnapshot) {
        Btn(
            if (s.isFavorite) R.drawable.ic_widget_heart_filled else R.drawable.ic_widget_heart,
            if (s.isFavorite) "Unfavorite" else "Favorite",
            cmd(ctx, WidgetCommand.Kind.FAVORITE, s, if (s.isFavorite) "0" else "1"),
            tint = if (s.isFavorite) ACCENT else FG,
        )
    }

    @Composable
    private fun Cover(bmp: Bitmap?, size: androidx.compose.ui.unit.Dp) {
        val m = GlanceModifier.size(size).cornerRadius(8.dp)
        if (bmp != null) Image(ImageProvider(bmp), "Cover art", m)
        else Box(m.background(PLACEHOLDER), contentAlignment = Alignment.Center) {
            Image(ImageProvider(R.drawable.ic_widget_note), null, GlanceModifier.size(size / 2), colorFilter = ColorFilter.tint(DIM))
        }
    }

    @Composable
    private fun Btn(res: Int, desc: String, action: Action, tint: ColorProvider = FG) {
        Image(
            ImageProvider(res), desc,
            GlanceModifier.size(40.dp).padding(8.dp).clickable(action),
            colorFilter = ColorFilter.tint(tint),
        )
    }

    private fun playGlyph(s: NowPlayingSnapshot) = if (s.isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play

    private fun key(ctx: Context, code: Int): Action =
        actionStartService(WidgetIntents.mediaButton(ctx, code), isForegroundService = true)

    private fun cmd(ctx: Context, kind: WidgetCommand.Kind, s: NowPlayingSnapshot, value: String?): Action =
        actionSendBroadcast(WidgetIntents.command(ctx, kind, s.songId, s.appleMusicId, value))

    private fun loadCover(store: NowPlayingSnapshotStore): Bitmap? = runCatching {
        if (!store.hasCover()) return null
        val path = store.coverFile.path
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= MAX_COVER_PX) sample *= 2
        BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
    }.getOrNull()

    companion object {
        private const val MAX_COVER_PX = 256
        val SMALL = DpSize(110.dp, 40.dp)
        val MEDIUM = DpSize(250.dp, 110.dp)
        val LARGE = DpSize(250.dp, 250.dp)
        private val BG = ColorProvider(Color(0xFF07101F))
        private val FG = ColorProvider(Color.White)
        private val DIM = ColorProvider(Color(0xFF9FB0C8))
        private val ACCENT = ColorProvider(Color(0xFF6EA8FF))
        private val PLACEHOLDER = ColorProvider(Color(0xFF16233A))
    }
}
