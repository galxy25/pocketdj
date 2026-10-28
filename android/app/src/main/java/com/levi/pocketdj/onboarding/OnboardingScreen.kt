package com.levi.pocketdj.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph

/** Title shown under the wordmark for each stage (iOS `stageTitle`). */
fun onboardingStageTitle(stage: OnboardingStage): String = when (stage) {
    OnboardingStage.Profile -> "Your profile"
    OnboardingStage.AppleMusic -> "Stream with Apple Music"
    OnboardingStage.Sources -> "Import your music"
}

/** The full-screen first-run gate the shell renders INSTEAD of the app while incomplete. */
@Composable
fun OnboardingScreen(graph: AppGraph, store: OnboardingStore) {
    val state by store.state.collectAsState()
    val stage = state.stage
    BackHandler(enabled = stage != OnboardingStage.Profile) { store.back() }

    Box(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)
            .safeDrawingPadding().testTag("onboarding-root"),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                Modifier.padding(top = 40.dp, bottom = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("PocketDJ", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
                Text(
                    onboardingStageTitle(stage),
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.testTag("onboarding-stage-title"),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag("onboarding-progress")) {
                    OnboardingStage.entries.forEach { s ->
                        Box(
                            Modifier.size(8.dp).clip(CircleShape).background(
                                if (s.raw <= stage.raw) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.outline,
                            ),
                        )
                    }
                }
            }
            Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
                when (stage) {
                    OnboardingStage.Profile -> OnboardingProfileStage(graph, store)
                    OnboardingStage.AppleMusic -> OnboardingAppleMusicStage(graph, store)
                    OnboardingStage.Sources -> OnboardingSourcesStage(graph, store)
                }
            }
        }
    }
}
