package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Compress
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Waves
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.ModSource

object FxChipRules {
    fun icon(e: Effect): ImageVector = when (e) {
        Effect.COMPRESSOR -> Icons.Filled.Compress
        Effect.REVERB -> Icons.Filled.GraphicEq
        Effect.FLANGER -> Icons.Filled.Waves
        Effect.FILTER -> Icons.Filled.FilterAlt
    }

    /** The chip shows the VARIETY ("Hall"/"HP"/"Glue"); the icon carries the family. */
    fun chipLabel(slot: FXSlot): String = slot.variant.label

    fun spoken(index: Int, slot: FXSlot) = "Slot ${index + 1}, ${slot.effect.label}, ${slot.variant.longLabel}"

    fun state(slot: FXSlot): String =
        if (slot.mod.source == ModSource.OFF) (if (slot.enabled) "on" else "off")
        else "${if (slot.enabled) "on" else "off"}, ${slot.mod.source.label} modulation"
}

/**
 * One rack slot chip. TAP toggles; LONG-PRESS enables the slot (dialling should be audible) and opens
 * the reveal: effect menu (left) · MOD · variety menu (right) above a strength slider with steppers.
 * Duplicates of a family are allowed. [onMod] is the MIX-17 modulation-sheet seam (placeholder disabled
 * until wired).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FxSlotChip(
    engine: MixEngine,
    deck: Deck,
    index: Int,
    tag: String,
    modifier: Modifier = Modifier,
    onMod: ((Deck, Int) -> Unit)? = null,
) {
    val ui by engine.ui.collectAsState()
    val slot = ui.deck(deck).slots.getOrNull(index) ?: FXSlot(Effect.COMPRESSOR)
    val isOn = slot.enabled
    var show by remember { mutableStateOf(false) }
    Box(modifier) {
        val shape = RoundedCornerShape(7.dp)
        Row(
            Modifier
                .fillMaxWidth()
                .background(if (isOn) DeckColors.accent.copy(alpha = 0.25f) else DeckColors.overlay, shape)
                .border(1.dp, if (isOn) DeckColors.accent else DeckColors.border, shape)
                .combinedClickable(
                    onClick = { engine.setSlot(index, !isOn, deck) },
                    onLongClick = {
                        if (!isOn) engine.setSlot(index, true, deck)
                        show = true
                    },
                )
                .heightIn(min = 32.dp)
                .padding(vertical = 7.dp)
                .testTag(tag)
                .semantics { contentDescription = FxChipRules.spoken(index, slot); stateDescription = FxChipRules.state(slot) },
            horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val c = if (isOn) DeckColors.accent else DeckColors.dim
            Icon(FxChipRules.icon(slot.effect), null, tint = c, modifier = Modifier.size(16.dp))
            Text(FxChipRules.chipLabel(slot), fontSize = 12.sp, fontWeight = FontWeight.Medium, color = c,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (slot.mod.source != ModSource.OFF) {
                Icon(Icons.Filled.Timeline, null, tint = c, modifier = Modifier.size(10.dp))
            }
        }
        if (show) FxReveal(engine, deck, index, tag, onMod) { show = false }
    }
}

@Composable
private fun FxReveal(engine: MixEngine, deck: Deck, index: Int, tag: String, onMod: ((Deck, Int) -> Unit)?, onDismiss: () -> Unit) {
    val ui by engine.ui.collectAsState()
    val slot = ui.deck(deck).slots.getOrNull(index) ?: return
    // Menus are open => browsing reads as idle: no auto-dismiss, outside-tap closes (iOS autoDismiss:false).
    ChipStrengthPopover(
        title = "Slot ${index + 1}", tint = DeckColors.accent, value = slot.strength, step = 0.05,
        tag = "$tag-strength", onDismiss = onDismiss, autoDismiss = false,
        header = {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                EffectMenu(engine, deck, index, slot, tag)
                Box(Modifier.weight(1f))
                ModButton(slot, tag, deck, index, onMod)
                Box(Modifier.width(6.dp))
                VariantMenu(engine, deck, index, slot, tag)
            }
        },
    ) { engine.setSlotStrength(index, it, deck) }
}

@Composable
private fun PickerLabel(text: String, icon: ImageVector?, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(5.dp)
    Row(
        modifier.background(DeckColors.overlay, shape).border(1.dp, DeckColors.border, shape).padding(horizontal = 6.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        if (icon != null) Icon(icon, null, tint = DeckColors.accent, modifier = Modifier.size(12.dp))
        Text(text, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.accent, maxLines = 1)
        Icon(Icons.Filled.ArrowDropDown, null, tint = DeckColors.accent, modifier = Modifier.size(12.dp))
    }
}

/** LEFT: swap which effect this slot holds, any family, even one already in another slot. */
@Composable
private fun EffectMenu(engine: MixEngine, deck: Deck, index: Int, slot: FXSlot, tag: String) {
    var open by remember { mutableStateOf(false) }
    Box {
        PickerLabel(slot.effect.label, FxChipRules.icon(slot.effect),
            Modifier.clickable { open = true }.testTag("$tag-effect")
                .semantics { contentDescription = "Effect"; stateDescription = slot.effect.label })
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            Effect.entries.forEach { fx ->
                DropdownMenuItem(
                    text = { Text(fx.label) },
                    leadingIcon = { Icon(if (fx == slot.effect) Icons.Filled.Check else FxChipRules.icon(fx), null) },
                    onClick = { engine.setSlotEffect(fx, index, deck); open = false },
                    modifier = Modifier.testTag("$tag-effect-${fx.raw}"),
                )
            }
        }
    }
}

/** RIGHT: pick a different variety of the effect the slot already holds. */
@Composable
private fun VariantMenu(engine: MixEngine, deck: Deck, index: Int, slot: FXSlot, tag: String) {
    var open by remember { mutableStateOf(false) }
    Box {
        PickerLabel(slot.variant.label, null,
            Modifier.clickable { open = true }.testTag("$tag-variant")
                .semantics { contentDescription = "Variety"; stateDescription = slot.variant.longLabel })
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            EffectVariant.all(slot.effect).forEach { v ->
                DropdownMenuItem(
                    text = { Text(v.longLabel) },
                    leadingIcon = { if (v == slot.variant) Icon(Icons.Filled.Check, null) },
                    onClick = { engine.setSlotVariant(v, index, deck); open = false },
                    modifier = Modifier.testTag("$tag-variant-${v.raw}"),
                )
            }
        }
    }
}

/** MOD slot: opens the MIX-17 modulation sheet when wired; a disabled placeholder until then. */
@Composable
private fun ModButton(slot: FXSlot, tag: String, deck: Deck, index: Int, onMod: ((Deck, Int) -> Unit)?) {
    val active = slot.mod.source != ModSource.OFF
    val shape = RoundedCornerShape(5.dp)
    Box(
        Modifier
            .size(width = 24.dp, height = 22.dp)
            .background(if (active) DeckColors.accent.copy(alpha = 0.3f) else DeckColors.overlay, shape)
            .border(1.dp, if (active) DeckColors.accent else DeckColors.border, shape)
            .clickable(enabled = onMod != null) { onMod?.invoke(deck, index) }
            .testTag("$tag-mod")
            .semantics { contentDescription = "Modulation"; stateDescription = slot.mod.source.label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Timeline, null, modifier = Modifier.size(12.dp),
            tint = if (onMod == null && !active) DeckColors.dim.copy(alpha = 0.5f) else if (active) DeckColors.accent else DeckColors.dim)
    }
}
