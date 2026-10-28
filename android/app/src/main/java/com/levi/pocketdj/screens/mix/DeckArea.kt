package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.Deck

/** iOS `MixDeckLayout`; [raw] matches the persisted setting values. */
enum class DeckLayout(val raw: String) {
    SIDE_BY_SIDE("sideBySide"), STACKED("stacked"), SINGLE("single");

    companion object {
        fun fromRaw(s: String?): DeckLayout = entries.firstOrNull { it.raw == s } ?: STACKED
    }
}

object DeckLayoutRules {
    /** Landscape (width > height, any device) ALWAYS shows the two-up board; the setting governs portrait. */
    fun effective(pref: DeckLayout, landscape: Boolean): DeckLayout = if (landscape) DeckLayout.SIDE_BY_SIDE else pref

    fun isLandscape(widthPx: Float, heightPx: Float) = widthPx > heightPx

    /** Either chevron flips to the other deck (only two exist). */
    fun flip(d: Deck): Deck = d.other

    /** Portrait two-up columns are cramped: Lead/Sync/Stems render icon-only there. */
    fun compactControls(layout: DeckLayout) = layout == DeckLayout.SIDE_BY_SIDE

    fun masterLabel(running: Boolean) = if (running) "Pause both decks" else "Play both decks"
    fun masterEnabled(aLoaded: Boolean, bLoaded: Boolean) = aLoaded || bLoaded
}

/**
 * The two decks per the Deck-layout setting: side-by-side · stacked · single (‹ › + dots). The engine
 * is app-scoped, so single mode's hidden deck keeps playing; only its view is unmounted.
 * [sourceMenu] is the per-deck crate picker slot (MIX-14).
 */
@Composable
fun DeckArea(
    host: DeckHost,
    layout: DeckLayout,
    landscape: Boolean,
    onLoad: (Deck) -> Unit,
    modifier: Modifier = Modifier,
    beatPulseEnabled: Boolean = false,
    sourceMenu: @Composable (Deck) -> Unit = {},
) {
    val effective = DeckLayoutRules.effective(layout, landscape)
    val compact = effective == DeckLayout.SIDE_BY_SIDE
    var visible by rememberSaveable { mutableStateOf(Deck.A.label) }
    val shown = Deck.fromLabel(visible) ?: Deck.A

    @Composable
    fun deck(d: Deck, m: Modifier = Modifier) = DeckView(
        host = host, deck = d, onLoad = { onLoad(d) }, modifier = m,
        beatPulseEnabled = beatPulseEnabled, compactControls = compact, sourceMenu = { sourceMenu(d) },
    )

    Box(modifier.fillMaxWidth().testTag("mix-deck-area")) {
        when (effective) {
            DeckLayout.SIDE_BY_SIDE -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                deck(Deck.A, Modifier.weight(1f)); deck(Deck.B, Modifier.weight(1f))
            }
            DeckLayout.STACKED -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                deck(Deck.A); deck(Deck.B)
            }
            DeckLayout.SINGLE -> Column(verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SwitchButton(next = false) { visible = DeckLayoutRules.flip(shown).label }
                    androidx.compose.runtime.key(shown) { deck(shown, Modifier.weight(1f)) }
                    SwitchButton(next = true) { visible = DeckLayoutRules.flip(shown).label }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Deck.entries.forEach { d ->
                        Box(Modifier.size(7.dp).background(if (d == shown) DeckColors.accent else DeckColors.border, CircleShape))
                    }
                }
            }
        }
    }
}

@Composable
private fun SwitchButton(next: Boolean, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(12.dp), color = DeckColors.raised, border = BorderStroke(1.dp, DeckColors.border),
        modifier = Modifier
            .width(30.dp)
            .fillMaxHeight()
            .clickable(onClick = onClick)
            .testTag(if (next) "mix-deck-next" else "mix-deck-prev")
            .semantics { contentDescription = if (next) "Next deck" else "Previous deck" },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                if (next) Icons.AutoMirrored.Filled.KeyboardArrowRight else Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                null, tint = DeckColors.accent, modifier = Modifier.size(26.dp),
            )
        }
    }
}

/** The single bottom Play/Pause for BOTH decks (`mix-play`). Disabled with nothing loaded. */
@Composable
fun MasterTransport(engine: MixEngine, modifier: Modifier = Modifier) {
    val ui by engine.ui.collectAsState()
    Button(
        onClick = { engine.toggleAll() },
        enabled = DeckLayoutRules.masterEnabled(ui.a.loaded != null, ui.b.loaded != null),
        colors = ButtonDefaults.buttonColors(containerColor = DeckColors.accent, contentColor = androidx.compose.ui.graphics.Color(0xFF07101F)),
        shape = RoundedCornerShape(12.dp),
        modifier = modifier.fillMaxWidth().testTag("mix-play"),
    ) {
        Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(if (ui.isRunning) Icons.Filled.Pause else Icons.Filled.PlayArrow, null)
            Text(DeckLayoutRules.masterLabel(ui.isRunning), fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
