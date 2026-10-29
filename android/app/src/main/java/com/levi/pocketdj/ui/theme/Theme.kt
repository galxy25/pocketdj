package com.levi.pocketdj.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

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
    outlineVariant = PdjOutlineVariant,
    // Every Material container token (cards, dialogs, sheets, menus, nav bar) is mapped onto
    // the navy ramp; left unset they fall back to the baseline neutral greys (off-palette).
    surfaceDim = PdjSurface,
    surfaceBright = PdjSurfaceContainerHighest,
    surfaceContainerLowest = PdjBackground,
    surfaceContainerLow = PdjSurface,
    surfaceContainer = PdjSurfaceVariant,
    surfaceContainerHigh = PdjSurfaceContainerHigh,
    surfaceContainerHighest = PdjSurfaceContainerHighest,
    surfaceTint = PdjAccent,
    inverseSurface = PdjOnBackground,
    inverseOnSurface = PdjBackground,
    inversePrimary = PdjAccentDim,
    primaryContainer = PdjAccentContainer,
    onPrimaryContainer = PdjOnBackground,
    secondaryContainer = PdjAccentContainer,
    onSecondaryContainer = PdjOnBackground,
    tertiary = PdjAccent,
    onTertiary = PdjOnAccent,
    tertiaryContainer = PdjAccentContainer,
    onTertiaryContainer = PdjOnBackground,
    scrim = Color.Black,
)

@Composable
fun PocketDjTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = PocketDjDarkColors,
        typography = PocketDjTypography,
    ) {
        // Root content colour: text drawn outside any Surface (onboarding wordmark, footers)
        // must default to the light on-background, not Compose's black fallback.
        CompositionLocalProvider(LocalContentColor provides PdjOnBackground, content = content)
    }
}
