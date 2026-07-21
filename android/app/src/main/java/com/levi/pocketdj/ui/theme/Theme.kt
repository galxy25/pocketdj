package com.levi.pocketdj.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

// PocketDJ is a dark-first app; we ship a single dark scheme keyed on the brand accent.
private val PocketDjDarkColors = darkColorScheme(
    primary = PdjAccent,
    onPrimary = PdjOnAccent,
    secondary = PdjAccent,
    onSecondary = PdjOnAccent,
    background = PdjBackground,
    onBackground = PdjOnBackground,
    surface = PdjSurface,
    onSurface = PdjOnBackground,
    surfaceVariant = PdjSurfaceVariant,
    onSurfaceVariant = PdjOnSurfaceVariant,
    outline = PdjOutline,
)

@Composable
fun PocketDjTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = PocketDjDarkColors,
        typography = PocketDjTypography,
        content = content,
    )
}
